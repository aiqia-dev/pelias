# Guia de Implementação - Pelias Optimizations

Este guia fornece instruções passo-a-passo para implementar as otimizações de performance no Pelias.

## 📋 Pré-requisitos

- Docker e Docker Compose instalados
- Mínimo 8GB RAM (16GB+ recomendado)
- 50GB+ de espaço em disco livre
- Linux ou macOS (Windows via WSL2)

## 🎯 Cenários de Implementação

Escolha o cenário que se aplica ao seu caso:

### Cenário A: Nova Instalação
✅ Você está instalando o Pelias pela primeira vez
→ Siga **Seção 1: Deploy Completo**

### Cenário B: Instalação Existente
✅ Você já tem Pelias rodando
→ Siga **Seção 2: Migração Gradual**

### Cenário C: Apenas Cache
✅ Você só quer adicionar cache
→ Siga **Seção 3: Cache Standalone**

---

## Seção 1: Deploy Completo (Nova Instalação)

### Passo 1: Preparar Ambiente

```bash
# Clone o repositório Pelias
git clone https://github.com/pelias/docker.git pelias-docker
cd pelias-docker

# Criar diretórios de dados
mkdir -p data/{elasticsearch,redis,placeholder,pip,interpolation}
mkdir -p logs
```

### Passo 2: Configuração

```bash
# Copiar configuração otimizada
cp /path/to/optimizations/config/pelias.optimized.json ./pelias.json

# Ajustar para seus dados (editar pelias.json)
# - Definir região/país de foco
# - Configurar sources de dados
# - Ajustar paths se necessário

# Validar configuração
cat pelias.json | jq .
```

### Passo 3: Deploy com Docker Compose

```bash
# Copiar docker-compose otimizado
cp /path/to/optimizations/config/docker-compose.optimized.yml ./docker-compose.yml

# IMPORTANTE: Ajustar heap do Elasticsearch baseado em RAM disponível
# Para 16GB RAM total: ES_JAVA_OPTS="-Xms6g -Xmx6g"
# Para 32GB RAM total: ES_JAVA_OPTS="-Xms12g -Xmx12g"

# Editar docker-compose.yml e ajustar ES_JAVA_OPTS

# Iniciar serviços
docker-compose up -d

# Verificar que todos subiram
docker-compose ps
```

### Passo 4: Aguardar Inicialização

```bash
# Verificar saúde do Elasticsearch (aguardar ficar "green")
watch -n 5 "curl -s localhost:9200/_cluster/health | jq ."

# Verificar Redis
redis-cli PING
# Resposta esperada: PONG

# Verificar microserviços
curl localhost:4100/health  # Placeholder
curl localhost:4200/health  # PIP
curl localhost:4400/health  # Libpostal
curl localhost:4300/health  # Interpolation
```

### Passo 5: Importar Dados

```bash
# Baixar dados (exemplo: Brasil)
docker-compose run --rm whosonfirst ./bin/download
docker-compose run --rm openaddresses ./bin/download
docker-compose run --rm openstreetmap ./bin/download

# Importar para Elasticsearch
docker-compose run --rm whosonfirst ./bin/start
docker-compose run --rm openaddresses ./bin/start
docker-compose run --rm openstreetmap ./bin/start

# Aguardar conclusão (pode levar horas dependendo do volume)
# Monitorar progresso:
docker logs -f pelias_openaddresses_1
```

### Passo 6: Otimizar Índice

```bash
# Após importação completa, otimizar
cd /path/to/optimizations/scripts
./optimize-elasticsearch.sh

# Aguardar force merge completar
```

### Passo 7: Testar

```bash
# Testar endpoints
curl "localhost:4000/v1/search?text=São Paulo"
curl "localhost:4000/v1/reverse?point.lat=-23.5505&point.lon=-46.6333"

# Executar suite de performance
./performance-test.sh

# Verificar cache funcionando
curl -I "localhost:4000/v1/search?text=test"
# Primeira request: X-Cache: MISS
# Segunda request: X-Cache: HIT
```

---

## Seção 2: Migração Gradual (Instalação Existente)

### Fase 1: Adicionar Redis

```bash
# Adicionar serviço Redis ao docker-compose.yml existente
cat >> docker-compose.yml << 'EOF'
  redis:
    image: redis:7-alpine
    container_name: pelias_redis
    command: >
      redis-server
      --maxmemory 2gb
      --maxmemory-policy allkeys-lru
    ports:
      - "6379:6379"
    volumes:
      - redis-data:/data
volumes:
  redis-data:
EOF

# Iniciar Redis
docker-compose up -d redis

# Testar
redis-cli PING
```

### Fase 2: Integrar Cache na API

```bash
# Copiar middleware de cache
cp /path/to/optimizations/cache/redis-cache-middleware.js ./api/
cp /path/to/optimizations/cache/package.json ./api/cache-package.json

# Instalar dependências
cd api
npm install redis@^3.1.2

# Modificar app.js para usar o cache
# Adicionar no início do arquivo:
```

```javascript
const PeliasCache = require('./redis-cache-middleware');
const cache = new PeliasCache({
  host: process.env.REDIS_HOST || 'redis',
  port: 6379,
  enabled: true
});

// Aplicar middleware ANTES das rotas
app.use('/v1', cache.middleware());
```

```bash
# Reiniciar API
docker-compose restart api
```

### Fase 3: Otimizar Elasticsearch

```bash
# Backup atual (importante!)
curl -XPUT "localhost:9200/_snapshot/backup_repo" -H 'Content-Type: application/json' -d '{
  "type": "fs",
  "settings": {
    "location": "/usr/share/elasticsearch/backups"
  }
}'

# Criar snapshot
curl -XPUT "localhost:9200/_snapshot/backup_repo/snapshot_1?wait_for_completion=true"

# Aplicar otimizações
cd /path/to/optimizations/scripts
./optimize-elasticsearch.sh

# Se algo der errado, restaurar:
# curl -XPOST "localhost:9200/_snapshot/backup_repo/snapshot_1/_restore"
```

### Fase 4: Adicionar Microserviços

```bash
# Verificar quais já estão rodando
docker-compose ps | grep -E "(libpostal|placeholder|pip|interpolation)"

# Adicionar os que faltam ao docker-compose.yml
# (Copiar do docker-compose.optimized.yml)

# Iniciar novos serviços
docker-compose up -d libpostal placeholder pip interpolation
```

### Fase 5: Atualizar Configuração

```bash
# Merge das configs
# Copiar seções relevantes de pelias.optimized.json para seu pelias.json:
# - services.placeholder.url
# - services.pip.url
# - services.libpostal.url
# - interpolation.client
# - api.customBoosts
# - api.queryCache

# Reiniciar API para aplicar
docker-compose restart api
```

---

## Seção 3: Cache Standalone

Se você só quer adicionar cache sem mudanças na infraestrutura:

### Opção 3A: NGINX Cache (Mais Simples)

```bash
# Instalar NGINX
docker run -d \
  --name pelias_nginx \
  -p 80:80 \
  -v /path/to/optimizations/config/nginx.conf:/etc/nginx/nginx.conf:ro \
  --link pelias_api:api \
  nginx:alpine

# Testar
curl "localhost/v1/search?text=test"

# Verificar cache
curl -I "localhost/v1/search?text=test" | grep X-Cache
```

### Opção 3B: Redis Cache (Mais Flexível)

```bash
# 1. Iniciar Redis
docker run -d \
  --name pelias_redis \
  -p 6379:6379 \
  -v redis-data:/data \
  redis:7-alpine \
  redis-server --maxmemory 2gb --maxmemory-policy allkeys-lru

# 2. Integrar middleware (ver Fase 2 acima)

# 3. Testar
curl "localhost:4000/v1/search?text=test"
# Verificar logs da API para mensagens de cache
```

---

## 🔍 Validação Pós-Implementação

### Checklist de Verificação

```bash
# 1. Todos os serviços rodando?
docker-compose ps
# Todos devem estar "Up"

# 2. Elasticsearch saudável?
curl localhost:9200/_cluster/health | jq -r .status
# Deve retornar: "green" ou "yellow"

# 3. Cache funcionando?
redis-cli DBSIZE
# Deve retornar número > 0 após alguns requests

# 4. API respondendo?
curl -w "%{time_total}\n" "localhost:4000/v1/search?text=test"
# Deve retornar < 0.5 segundos

# 5. Microserviços conectados?
docker logs pelias_api | grep -E "(libpostal|placeholder|pip)"
# Deve mostrar conexões bem-sucedidas
```

### Testes de Performance

```bash
# Executar suite completa
cd /path/to/optimizations/scripts
./performance-test.sh > results.txt

# Comparar com baseline
# - Cold cache: deve estar similar ao anterior
# - Warm cache: deve ser 3-10x mais rápido
# - Cache hit rate: deve ser > 50%
```

---

## ⚠️ Troubleshooting Comum

### Problema: Elasticsearch OOM (Out of Memory)

```bash
# Sintoma: Elasticsearch crasha ou fica lento
# Solução: Reduzir heap size

# Editar docker-compose.yml:
ES_JAVA_OPTS: "-Xms2g -Xmx2g"  # Reduzir de 4g para 2g

# Reiniciar
docker-compose restart elasticsearch
```

### Problema: Cache não está sendo usado

```bash
# Debug: Verificar conexão Redis
docker exec pelias_api nc -zv redis 6379

# Debug: Ver logs da API
docker logs pelias_api | grep -i cache

# Debug: Verificar middleware está aplicado
docker exec pelias_api grep -r "cache.middleware()" /code/

# Se não encontrar, middleware não foi integrado corretamente
```

### Problema: Queries ainda lentas

```bash
# 1. Verificar se microserviços estão sendo usados
docker logs pelias_api | grep -E "(libpostal|placeholder|pip)" | tail -20

# 2. Checar se ES está sobrecarregado
curl localhost:9200/_cat/thread_pool?v&h=name,queue,rejected

# 3. Se queue > 0 ou rejected > 0, ES está sobrecarregado:
#    - Aumentar heap
#    - Ou reduzir concorrência de importação
#    - Ou adicionar mais nós ES
```

---

## 📊 Métricas de Sucesso

Após implementação, você deve ver:

| Métrica | Alvo | Como Medir |
|---------|------|------------|
| Latência P50 | < 100ms | `performance-test.sh` |
| Latência P95 | < 300ms | Apache Bench |
| Cache Hit Rate | > 60% | `redis-cli INFO stats` |
| ES Heap Usage | < 75% | `curl localhost:9200/_cat/nodes?v` |
| Taxa de Sucesso | > 95% | Logs da API |
| Throughput | > 100 req/s | Load test |

---

## 🚀 Próximos Passos

Depois de tudo funcionando:

1. **Monitoramento Contínuo**
   - Setup Prometheus + Grafana para métricas
   - Alertas para heap > 80%, cache hit < 50%

2. **Otimização Contínua**
   - Ajustar TTLs baseado em padrões reais
   - A/B test diferentes configurações
   - Profiling de queries lentas

3. **Scaling**
   - Se heap > 75% consistente: adicionar nó ES
   - Se CPU > 80%: scale horizontal da API
   - Se Redis > 2GB: aumentar maxmemory

4. **Backups**
   - Setup snapshots automáticos do ES
   - Backup periódico da config do Redis

---

**Precisa de ajuda?** Abra uma issue no repositório!
