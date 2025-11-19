#!/bin/bash

##############################################################################
# Quick Deploy Script
# One-command deployment of optimized Pelias
##############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}║      PELIAS OPTIMIZED - QUICK DEPLOY SCRIPT          ║${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

# Check dependencies
echo -e "${YELLOW}[1/10] Checking dependencies...${NC}"
MISSING_DEPS=()

if ! command -v docker &> /dev/null; then
    MISSING_DEPS+=("docker")
fi

if ! command -v docker-compose &> /dev/null; then
    MISSING_DEPS+=("docker-compose")
fi

if ! command -v jq &> /dev/null; then
    MISSING_DEPS+=("jq")
fi

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo -e "${RED}ERROR: Missing dependencies: ${MISSING_DEPS[*]}${NC}"
    echo "Please install them and try again."
    exit 1
fi

echo -e "${GREEN}✓ All dependencies installed${NC}"
echo ""

# Get system specs
echo -e "${YELLOW}[2/10] Detecting system resources...${NC}"
TOTAL_RAM_GB=$(free -g | grep Mem | awk '{print $2}')
AVAILABLE_DISK_GB=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')

echo -e "  RAM: ${TOTAL_RAM_GB}GB"
echo -e "  Available Disk: ${AVAILABLE_DISK_GB}GB"

# Recommend ES heap
if [ "$TOTAL_RAM_GB" -ge 32 ]; then
    ES_HEAP="12g"
elif [ "$TOTAL_RAM_GB" -ge 16 ]; then
    ES_HEAP="6g"
elif [ "$TOTAL_RAM_GB" -ge 8 ]; then
    ES_HEAP="3g"
else
    echo -e "${RED}WARNING: Only ${TOTAL_RAM_GB}GB RAM detected. Minimum 8GB recommended.${NC}"
    ES_HEAP="2g"
fi

echo -e "  Recommended ES Heap: ${GREEN}$ES_HEAP${NC}"
echo ""

# Warnings
if [ "$TOTAL_RAM_GB" -lt 8 ]; then
    echo -e "${RED}⚠️  WARNING: Less than 8GB RAM. Performance may be poor.${NC}"
fi

if [ "$AVAILABLE_DISK_GB" -lt 50 ]; then
    echo -e "${YELLOW}⚠️  WARNING: Less than 50GB free disk. Consider freeing space.${NC}"
fi

# Ask for confirmation
echo -e "${YELLOW}[3/10] Configuration:${NC}"
echo "  ES Heap: $ES_HEAP"
echo "  Redis Max Memory: 2GB"
echo "  All microservices: enabled"
echo ""

read -p "Continue with deployment? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 0
fi
echo ""

# Create directories
echo -e "${YELLOW}[4/10] Creating directories...${NC}"
mkdir -p data/{elasticsearch,redis,placeholder,pip,interpolation}
mkdir -p logs
echo -e "${GREEN}✓ Directories created${NC}"
echo ""

# Copy configurations
echo -e "${YELLOW}[5/10] Copying configurations...${NC}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(dirname "$SCRIPT_DIR")/config"

if [ -f "$CONFIG_DIR/pelias.optimized.json" ]; then
    cp "$CONFIG_DIR/pelias.optimized.json" ./pelias.json
    echo -e "${GREEN}✓ pelias.json copied${NC}"
else
    echo -e "${RED}ERROR: pelias.optimized.json not found${NC}"
    exit 1
fi

if [ -f "$CONFIG_DIR/docker-compose.optimized.yml" ]; then
    cp "$CONFIG_DIR/docker-compose.optimized.yml" ./docker-compose.yml

    # Update ES heap in docker-compose
    sed -i "s/-Xms4g -Xmx4g/-Xms$ES_HEAP -Xmx$ES_HEAP/g" docker-compose.yml
    echo -e "${GREEN}✓ docker-compose.yml copied and configured${NC}"
else
    echo -e "${RED}ERROR: docker-compose.optimized.yml not found${NC}"
    exit 1
fi

# Copy other configs
if [ -f "$CONFIG_DIR/elasticsearch.yml" ]; then
    cp "$CONFIG_DIR/elasticsearch.yml" ./elasticsearch.yml
fi

if [ -f "$CONFIG_DIR/nginx.conf" ]; then
    cp "$CONFIG_DIR/nginx.conf" ./nginx.conf
fi

echo ""

# Pull images
echo -e "${YELLOW}[6/10] Pulling Docker images...${NC}"
echo "This may take a while on first run..."
docker-compose pull
echo -e "${GREEN}✓ Images pulled${NC}"
echo ""

# Start services
echo -e "${YELLOW}[7/10] Starting services...${NC}"
docker-compose up -d
echo -e "${GREEN}✓ Services started${NC}"
echo ""

# Wait for Elasticsearch
echo -e "${YELLOW}[8/10] Waiting for Elasticsearch to be ready...${NC}"
MAX_WAIT=120
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -sf "http://localhost:9200/_cluster/health" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Elasticsearch is ready${NC}"
        break
    fi
    echo -n "."
    sleep 5
    WAITED=$((WAITED + 5))
done

if [ $WAITED -ge $MAX_WAIT ]; then
    echo -e "${RED}ERROR: Elasticsearch failed to start within ${MAX_WAIT}s${NC}"
    echo "Check logs: docker logs pelias_elasticsearch"
    exit 1
fi
echo ""

# Verify all services
echo -e "${YELLOW}[9/10] Verifying services...${NC}"

SERVICES=(
    "elasticsearch:9200:/_cluster/health"
    "redis:6379:PING"
    "libpostal:4400:/health"
    "placeholder:4100:/health"
    "pip:4200:/health"
    "interpolation:4300:/health"
    "api:4000:/v1/health"
)

ALL_OK=true
for service in "${SERVICES[@]}"; do
    IFS=':' read -r name port endpoint <<< "$service"

    if [ "$name" = "redis" ]; then
        if redis-cli -h localhost PING > /dev/null 2>&1; then
            echo -e "  $name: ${GREEN}✓${NC}"
        else
            echo -e "  $name: ${RED}✗${NC}"
            ALL_OK=false
        fi
    else
        if curl -sf "http://localhost:${port}${endpoint}" > /dev/null 2>&1; then
            echo -e "  $name: ${GREEN}✓${NC}"
        else
            echo -e "  $name: ${YELLOW}⚠${NC} (may need more time)"
        fi
    fi
done

echo ""

# Display status
echo -e "${YELLOW}[10/10] Deployment Summary${NC}"
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}║  🎉  PELIAS OPTIMIZED DEPLOYED SUCCESSFULLY!         ║${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Services:${NC}"
echo -e "  📊 Elasticsearch:   http://localhost:9200"
echo -e "  💾 Redis:           localhost:6379"
echo -e "  🌐 API:             http://localhost:4000"
echo -e "  🔧 NGINX:           http://localhost:80"
echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo ""
echo -e "1. ${YELLOW}Import data:${NC}"
echo "   docker-compose run --rm whosonfirst ./bin/download"
echo "   docker-compose run --rm openaddresses ./bin/download"
echo "   docker-compose run --rm openstreetmap ./bin/download"
echo "   docker-compose run --rm whosonfirst ./bin/start"
echo "   docker-compose run --rm openaddresses ./bin/start"
echo "   docker-compose run --rm openstreetmap ./bin/start"
echo ""
echo -e "2. ${YELLOW}Test the API:${NC}"
echo "   curl 'localhost:4000/v1/search?text=São Paulo'"
echo ""
echo -e "3. ${YELLOW}Monitor performance:${NC}"
echo "   $SCRIPT_DIR/monitor.sh"
echo ""
echo -e "4. ${YELLOW}Run performance tests:${NC}"
echo "   $SCRIPT_DIR/performance-test.sh"
echo ""
echo -e "5. ${YELLOW}After data import, optimize:${NC}"
echo "   $SCRIPT_DIR/optimize-elasticsearch.sh"
echo ""
echo -e "${GREEN}Logs:${NC}"
echo "  docker-compose logs -f"
echo ""
echo -e "${GREEN}Stop:${NC}"
echo "  docker-compose down"
echo ""
