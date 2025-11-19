#!/bin/bash

##############################################################################
# Pelias Monitoring Script
# Real-time monitoring of all components
##############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
ES_HOST="${ES_HOST:-localhost:9200}"
REDIS_HOST="${REDIS_HOST:-localhost}"
API_HOST="${API_HOST:-localhost:4000}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-5}"

clear

while true; do
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}         ${GREEN}PELIAS PERFORMANCE MONITOR${NC}                      ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}Last update: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo ""

    # ===================================
    # ELASTICSEARCH STATUS
    # ===================================
    echo -e "${YELLOW}━━━ ELASTICSEARCH ━━━${NC}"

    if ES_HEALTH=$(curl -sf "http://$ES_HOST/_cluster/health" 2>/dev/null); then
        STATUS=$(echo "$ES_HEALTH" | jq -r '.status')
        NODES=$(echo "$ES_HEALTH" | jq -r '.number_of_nodes')
        ACTIVE_SHARDS=$(echo "$ES_HEALTH" | jq -r '.active_shards')

        if [ "$STATUS" = "green" ]; then
            echo -e "  Status: ${GREEN}●${NC} $STATUS"
        elif [ "$STATUS" = "yellow" ]; then
            echo -e "  Status: ${YELLOW}●${NC} $STATUS"
        else
            echo -e "  Status: ${RED}●${NC} $STATUS"
        fi

        echo -e "  Nodes: $NODES | Active Shards: $ACTIVE_SHARDS"

        # Heap usage
        if HEAP=$(curl -sf "http://$ES_HOST/_cat/nodes?h=heap.percent&format=json" 2>/dev/null); then
            HEAP_PERCENT=$(echo "$HEAP" | jq -r '.[0]."heap.percent"')
            if [ ! -z "$HEAP_PERCENT" ]; then
                if [ "$HEAP_PERCENT" -lt 75 ]; then
                    echo -e "  Heap: ${GREEN}${HEAP_PERCENT}%${NC}"
                elif [ "$HEAP_PERCENT" -lt 90 ]; then
                    echo -e "  Heap: ${YELLOW}${HEAP_PERCENT}%${NC}"
                else
                    echo -e "  Heap: ${RED}${HEAP_PERCENT}%${NC} ⚠️"
                fi
            fi
        fi

        # Index stats
        if INDEX_STATS=$(curl -sf "http://$ES_HOST/pelias/_stats" 2>/dev/null); then
            DOC_COUNT=$(echo "$INDEX_STATS" | jq -r '._all.primaries.docs.count')
            INDEX_SIZE=$(echo "$INDEX_STATS" | jq -r '._all.primaries.store.size_in_bytes')
            INDEX_SIZE_GB=$(echo "scale=2; $INDEX_SIZE / 1024 / 1024 / 1024" | bc)

            echo -e "  Documents: $(printf "%'d" $DOC_COUNT)"
            echo -e "  Index Size: ${INDEX_SIZE_GB} GB"
        fi
    else
        echo -e "  Status: ${RED}● OFFLINE${NC}"
    fi
    echo ""

    # ===================================
    # REDIS CACHE STATUS
    # ===================================
    echo -e "${YELLOW}━━━ REDIS CACHE ━━━${NC}"

    if redis-cli -h "$REDIS_HOST" PING > /dev/null 2>&1; then
        echo -e "  Status: ${GREEN}● ONLINE${NC}"

        # Memory usage
        USED_MEMORY=$(redis-cli -h "$REDIS_HOST" INFO memory | grep "used_memory_human:" | cut -d: -f2 | tr -d '\r')
        MAX_MEMORY=$(redis-cli -h "$REDIS_HOST" CONFIG GET maxmemory | tail -1)

        if [ "$MAX_MEMORY" = "0" ]; then
            MAX_MEMORY_HUMAN="unlimited"
        else
            MAX_MEMORY_GB=$(echo "scale=2; $MAX_MEMORY / 1024 / 1024 / 1024" | bc)
            MAX_MEMORY_HUMAN="${MAX_MEMORY_GB}GB"
        fi

        echo -e "  Memory: $USED_MEMORY / $MAX_MEMORY_HUMAN"

        # Keys count
        KEYS_COUNT=$(redis-cli -h "$REDIS_HOST" DBSIZE)
        echo -e "  Cached Keys: $(printf "%'d" $KEYS_COUNT)"

        # Hit rate
        STATS=$(redis-cli -h "$REDIS_HOST" INFO stats)
        HITS=$(echo "$STATS" | grep "keyspace_hits:" | cut -d: -f2 | tr -d '\r')
        MISSES=$(echo "$STATS" | grep "keyspace_misses:" | cut -d: -f2 | tr -d '\r')

        if [ ! -z "$HITS" ] && [ ! -z "$MISSES" ]; then
            TOTAL=$((HITS + MISSES))
            if [ $TOTAL -gt 0 ]; then
                HIT_RATE=$(echo "scale=1; $HITS * 100 / $TOTAL" | bc)
                if (( $(echo "$HIT_RATE > 70" | bc -l) )); then
                    echo -e "  Hit Rate: ${GREEN}${HIT_RATE}%${NC} (Excellent)"
                elif (( $(echo "$HIT_RATE > 50" | bc -l) )); then
                    echo -e "  Hit Rate: ${YELLOW}${HIT_RATE}%${NC} (Good)"
                else
                    echo -e "  Hit Rate: ${RED}${HIT_RATE}%${NC} (Poor)"
                fi
            fi
        fi
    else
        echo -e "  Status: ${RED}● OFFLINE${NC}"
    fi
    echo ""

    # ===================================
    # API STATUS
    # ===================================
    echo -e "${YELLOW}━━━ PELIAS API ━━━${NC}"

    if API_HEALTH=$(curl -sf "http://$API_HOST/v1/search?text=test&size=1" 2>/dev/null); then
        echo -e "  Status: ${GREEN}● ONLINE${NC}"

        # Test response time
        RESPONSE_TIME=$(curl -sf -w "%{time_total}" -o /dev/null "http://$API_HOST/v1/search?text=São+Paulo&size=1")
        RESPONSE_MS=$(echo "$RESPONSE_TIME * 1000" | bc)

        if (( $(echo "$RESPONSE_TIME < 0.2" | bc -l) )); then
            echo -e "  Response Time: ${GREEN}${RESPONSE_MS}ms${NC} (Fast)"
        elif (( $(echo "$RESPONSE_TIME < 0.5" | bc -l) )); then
            echo -e "  Response Time: ${YELLOW}${RESPONSE_MS}ms${NC} (OK)"
        else
            echo -e "  Response Time: ${RED}${RESPONSE_MS}ms${NC} (Slow)"
        fi
    else
        echo -e "  Status: ${RED}● OFFLINE${NC}"
    fi
    echo ""

    # ===================================
    # MICROSERVICES STATUS
    # ===================================
    echo -e "${YELLOW}━━━ MICROSERVICES ━━━${NC}"

    # Libpostal
    if curl -sf "http://localhost:4400/health" > /dev/null 2>&1; then
        echo -e "  Libpostal:      ${GREEN}● ONLINE${NC}"
    else
        echo -e "  Libpostal:      ${RED}● OFFLINE${NC}"
    fi

    # Placeholder
    if curl -sf "http://localhost:4100/health" > /dev/null 2>&1; then
        echo -e "  Placeholder:    ${GREEN}● ONLINE${NC}"
    else
        echo -e "  Placeholder:    ${RED}● OFFLINE${NC}"
    fi

    # PIP
    if curl -sf "http://localhost:4200/health" > /dev/null 2>&1; then
        echo -e "  PIP:            ${GREEN}● ONLINE${NC}"
    else
        echo -e "  PIP:            ${RED}● OFFLINE${NC}"
    fi

    # Interpolation
    if curl -sf "http://localhost:4300/health" > /dev/null 2>&1; then
        echo -e "  Interpolation:  ${GREEN}● ONLINE${NC}"
    else
        echo -e "  Interpolation:  ${RED}● OFFLINE${NC}"
    fi
    echo ""

    # ===================================
    # SYSTEM RESOURCES
    # ===================================
    echo -e "${YELLOW}━━━ SYSTEM RESOURCES ━━━${NC}"

    # CPU
    if command -v top &> /dev/null; then
        CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
        if (( $(echo "$CPU_USAGE < 70" | bc -l) )); then
            echo -e "  CPU: ${GREEN}${CPU_USAGE}%${NC}"
        elif (( $(echo "$CPU_USAGE < 90" | bc -l) )); then
            echo -e "  CPU: ${YELLOW}${CPU_USAGE}%${NC}"
        else
            echo -e "  CPU: ${RED}${CPU_USAGE}%${NC} ⚠️"
        fi
    fi

    # Memory
    if command -v free &> /dev/null; then
        MEM_USAGE=$(free | grep Mem | awk '{printf("%.1f"), $3/$2 * 100}')
        if (( $(echo "$MEM_USAGE < 80" | bc -l) )); then
            echo -e "  Memory: ${GREEN}${MEM_USAGE}%${NC}"
        elif (( $(echo "$MEM_USAGE < 95" | bc -l) )); then
            echo -e "  Memory: ${YELLOW}${MEM_USAGE}%${NC}"
        else
            echo -e "  Memory: ${RED}${MEM_USAGE}%${NC} ⚠️"
        fi
    fi

    # Disk
    if command -v df &> /dev/null; then
        DISK_USAGE=$(df -h / | tail -1 | awk '{print $5}' | sed 's/%//')
        if [ "$DISK_USAGE" -lt 80 ]; then
            echo -e "  Disk: ${GREEN}${DISK_USAGE}%${NC}"
        elif [ "$DISK_USAGE" -lt 90 ]; then
            echo -e "  Disk: ${YELLOW}${DISK_USAGE}%${NC}"
        else
            echo -e "  Disk: ${RED}${DISK_USAGE}%${NC} ⚠️"
        fi
    fi
    echo ""

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Press Ctrl+C to exit | Refresh every ${REFRESH_INTERVAL}s${NC}"

    sleep $REFRESH_INTERVAL
done
