#!/bin/bash

##############################################################################
# Pelias Performance Testing Script
# Tests response times and cache effectiveness
##############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
API_URL="${API_URL:-http://localhost:4000}"
REQUESTS_PER_TEST="${REQUESTS_PER_TEST:-100}"
CONCURRENCY="${CONCURRENCY:-10}"

echo -e "${GREEN}=== Pelias Performance Test ===${NC}"
echo "API URL: $API_URL"
echo "Requests: $REQUESTS_PER_TEST"
echo "Concurrency: $CONCURRENCY"
echo ""

# Check if API is running
echo -e "${YELLOW}Checking API connectivity...${NC}"
if ! curl -sf "$API_URL/v1/health" > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Cannot connect to API at $API_URL${NC}"
    exit 1
fi
echo -e "${GREEN}✓ API is online${NC}"
echo ""

# Test queries
declare -A QUERIES=(
    ["search_address"]="/v1/search?text=Avenida Paulista 1578, São Paulo, SP"
    ["search_city"]="/v1/search?text=São Paulo"
    ["search_postalcode"]="/v1/search?text=01310-100"
    ["structured"]="/v1/search/structured?address=Rua Augusta 123&locality=São Paulo&region=SP"
    ["reverse"]="/v1/reverse?point.lat=-23.5505&point.lon=-46.6333"
    ["autocomplete"]="/v1/autocomplete?text=São Paulo"
)

# Function to test endpoint
test_endpoint() {
    local name=$1
    local endpoint=$2
    local url="${API_URL}${endpoint}"

    echo -e "${BLUE}Testing: $name${NC}"
    echo "Endpoint: $endpoint"

    # First request (cold cache)
    echo -n "  Cold cache: "
    COLD_TIME=$(curl -sf -w "%{time_total}" -o /dev/null "$url")
    echo -e "${YELLOW}${COLD_TIME}s${NC}"

    # Wait a bit
    sleep 1

    # Second request (warm cache)
    echo -n "  Warm cache: "
    WARM_TIME=$(curl -sf -w "%{time_total}" -o /dev/null "$url")
    CACHE_STATUS=$(curl -sf -I "$url" | grep -i "x-cache" | awk '{print $2}' || echo "UNKNOWN")
    echo -e "${GREEN}${WARM_TIME}s (Cache: $CACHE_STATUS)${NC}"

    # Calculate speedup
    SPEEDUP=$(echo "scale=2; $COLD_TIME / $WARM_TIME" | bc)
    echo -e "  ${GREEN}Speedup: ${SPEEDUP}x${NC}"
    echo ""
}

# Run tests
echo -e "${GREEN}=== Running Performance Tests ===${NC}"
echo ""

for name in "${!QUERIES[@]}"; do
    test_endpoint "$name" "${QUERIES[$name]}"
done

# Load test with Apache Bench (if available)
if command -v ab &> /dev/null; then
    echo -e "${GREEN}=== Load Testing with Apache Bench ===${NC}"
    echo ""

    TEST_URL="${API_URL}/v1/search?text=São+Paulo"
    echo "Testing: $TEST_URL"
    echo "Running $REQUESTS_PER_TEST requests with concurrency $CONCURRENCY..."
    echo ""

    ab -n "$REQUESTS_PER_TEST" -c "$CONCURRENCY" -g /tmp/ab_results.tsv "$TEST_URL" 2>&1 | grep -E "(Requests per second|Time per request|Transfer rate|succeeded|failed)"
    echo ""
else
    echo -e "${YELLOW}Apache Bench not installed. Skipping load test.${NC}"
    echo "Install with: apt-get install apache2-utils"
    echo ""
fi

# Cache statistics (if Redis is accessible)
if command -v redis-cli &> /dev/null; then
    echo -e "${GREEN}=== Redis Cache Statistics ===${NC}"
    REDIS_HOST="${REDIS_HOST:-localhost}"

    if redis-cli -h "$REDIS_HOST" PING > /dev/null 2>&1; then
        echo "Redis Host: $REDIS_HOST"
        echo ""

        echo "Cache Info:"
        redis-cli -h "$REDIS_HOST" INFO stats | grep -E "(keyspace_hits|keyspace_misses|used_memory_human)"
        echo ""

        echo "Key Count:"
        redis-cli -h "$REDIS_HOST" DBSIZE
        echo ""

        # Calculate hit rate
        HITS=$(redis-cli -h "$REDIS_HOST" INFO stats | grep keyspace_hits | cut -d: -f2 | tr -d '\r')
        MISSES=$(redis-cli -h "$REDIS_HOST" INFO stats | grep keyspace_misses | cut -d: -f2 | tr -d '\r')

        if [ ! -z "$HITS" ] && [ ! -z "$MISSES" ]; then
            TOTAL=$((HITS + MISSES))
            if [ $TOTAL -gt 0 ]; then
                HIT_RATE=$(echo "scale=2; $HITS * 100 / $TOTAL" | bc)
                echo -e "Cache Hit Rate: ${GREEN}${HIT_RATE}%${NC}"
            fi
        fi
        echo ""
    else
        echo -e "${YELLOW}Redis not accessible at $REDIS_HOST${NC}"
        echo ""
    fi
fi

# Summary
echo -e "${GREEN}=== Performance Test Complete ===${NC}"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Review response times above"
echo "2. Check cache hit rate (should be > 50% for production)"
echo "3. Monitor Elasticsearch heap: curl $API_URL/../elasticsearch/_cat/nodes?v"
echo "4. Consider scaling if response times > 500ms"
echo ""
