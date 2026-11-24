#!/usr/bin/env bash
set -euo pipefail
umask 077

# ==============================================================================
# Missão Antigravity CLI: Construindo Inteligência Editorial em Escala no Google Cloud
# ==============================================================================
# Desbloqueie desafios reais direto no terminal! Use o Antigravity CLI (agy) para
# expandir um pipeline com Gemini Decisions API, Cloud Run e BigQuery/Dataform:
# crie filas inteligentes de checagem de fatos, meça latência e gere relatórios via CLI.
#
# Regras de progressão (gates):
#   Gate 0 (Pré-requisitos): ./project.sh + ./deploy.sh + ./dataform.sh
#     -> Só libera o enunciado da Tarefa 1 após validar os 3 passos no GCP.
#   Gate 1 (Tarefa 1): Triagem Editorial Multi-Critério (Cloud Run + Dataform)
#     -> Só libera o enunciado da Tarefa 2 após validar código, testes e deploy.
#   Gate 2 (Tarefa 2): Telemetria de Latência, Matriz de Confusão e CLI Report
#     -> Valida a entrega final ponta a ponta e conclui o workshop.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNCTION_DIR="${SCRIPT_DIR}/function"
DEFINITIONS_DIR="${SCRIPT_DIR}/definitions"
STATE_DIR="${SCRIPT_DIR}/.workshop"
STATE_FILE="${STATE_DIR}/state.json"

PROJECT_FILE="${PROJECT_FILE:-$HOME/project_id.txt}"
DATAFORM_API_BASE="https://dataform.googleapis.com/v1"
PYTHON_BIN="${PYTHON_BIN:-python3}"

SUBCOMMAND="status"
DEPLOY_ARGS=()

# ------------------------------------------------------------------------------
# Formatação Visual
# ------------------------------------------------------------------------------
banner() {
  printf '\n==============================================================================\n'
  printf '  %s\n' "$1"
  printf '==============================================================================\n'
}

section() {
  printf '\n── %s ──\n' "$1"
}

ok() {
  printf '  [✓] %s\n' "$1"
}

fail_msg() {
  printf '  [✗] %s\n' "$1" >&2
}

locked_msg() {
  printf '  [🔒 BLOQUEADA] %s\n' "$1"
}

unlocked_msg() {
  printf '  [🔓 LIBERADA]  %s\n' "$1"
}

done_msg() {
  printf '  [🏆 CONCLUÍDA] %s\n' "$1"
}

info_msg() {
  printf '  [i] %s\n' "$1"
}

# ------------------------------------------------------------------------------
# Uso / CLI
# ------------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Uso: ./workshop.sh [COMANDO] [OPÇÕES]

Missão Antigravity CLI: Construindo Inteligência Editorial em Escala no Google Cloud
Desbloqueie desafios reais direto no terminal! Use o Antigravity CLI (agy) para
expandir um pipeline com Gemini Decisions API, Cloud Run e BigQuery/Dataform.

Comandos:
  status          (padrão) Verifica os pré-requisitos, mostra seu progresso atual
                  e exibe o enunciado da etapa desbloqueada no momento.
  validate        Valida a entrega atual (código, testes, Cloud Run e Dataform/BigQuery)
                  e desbloqueia a próxima tarefa se todos os critérios passarem.
  deploy [-q]     Atalho para validar segurança localmente, publicar nova revisão no
                  Cloud Run (./deploy.sh) e sincronizar/executar Dataform (./dataform.sh --run).
  reset           Limpa apenas o cache local de progresso (.workshop/state.json) para
                  revalidar todas as etapas novamente.
  -h, --help      Exibe esta mensagem de ajuda.

Variáveis de ambiente opcionais (mesmos padrões de deploy.sh / dataform.sh):
  PROJECT_ID               ID do projeto GCP (padrão: ~/project_id.txt ou gcloud config)
  REGION                   Região Cloud Run (padrão: us-central1)
  DATAFORM_LOCATION        Região Dataform (padrão: REGION)
  BQ_LOCATION              Localização BigQuery (padrão: US)
  FUNCTION_NAME            Serviço Cloud Run (padrão: bbc-news-decisions-rf)
  BQ_DATASET               Dataset BigQuery (padrão: bbc_news_eval)
  BQ_CONNECTION_ID         Conexão BigQuery (padrão: gemini-decisions-conn)
  DATAFORM_REPO_ID         Repositório Dataform (padrão: google-decision-api-demo)
  DATAFORM_RELEASE_CONFIG_ID Release config Dataform (padrão: production)
EOF
}

parse_args() {
  if [[ "$#" -eq 0 ]]; then
    SUBCOMMAND="status"
    return 0
  fi

  case "$1" in
    status|validate|reset)
      SUBCOMMAND="$1"
      shift
      if [[ "$#" -gt 0 ]]; then
        printf 'ERRO: Argumento inesperado para '\''%s'\'': %s\n' "${SUBCOMMAND}" "$1" >&2
        exit 1
      fi
      ;;
    deploy)
      SUBCOMMAND="deploy"
      shift
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          -q|--quiet)
            DEPLOY_ARGS+=("--quiet")
            ;;
          *)
            printf 'ERRO: Opção desconhecida para deploy: '\''%s'\''. Use -q/--quiet.\n' "$1" >&2
            exit 1
            ;;
        esac
        shift
      done
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      printf 'ERRO: Comando desconhecido '\''%s'\''. Execute ./workshop.sh --help.\n' "$1" >&2
      exit 1
      ;;
  esac
}

# ------------------------------------------------------------------------------
# Configuração & Estado Local (.workshop/state.json)
# ------------------------------------------------------------------------------
load_config() {
  local file_project=""
  if [[ -f "${PROJECT_FILE}" ]]; then
    file_project="$(tr -d '[:space:]' < "${PROJECT_FILE}" || true)"
  fi

  local gcloud_project=""
  if command -v gcloud >/dev/null 2>&1; then
    gcloud_project="$(gcloud config get-value project 2>/dev/null || true)"
    if [[ "${gcloud_project}" == "(unset)" ]]; then
      gcloud_project=""
    fi
  fi

  PROJECT_ID="${PROJECT_ID:-${gcloud_project:-${file_project}}}"
  REGION="${REGION:-us-central1}"
  DATAFORM_LOCATION="${DATAFORM_LOCATION:-${REGION}}"
  BQ_LOCATION="${BQ_LOCATION:-US}"
  FUNCTION_NAME="${FUNCTION_NAME:-bbc-news-decisions-rf}"
  BQ_DATASET="${BQ_DATASET:-bbc_news_eval}"
  BQ_CONNECTION_ID="${BQ_CONNECTION_ID:-gemini-decisions-conn}"
  DATAFORM_REPO_ID="${DATAFORM_REPO_ID:-google-decision-api-demo}"
  DATAFORM_RELEASE_CONFIG_ID="${DATAFORM_RELEASE_CONFIG_ID:-production}"

  CLOUD_RUN_URL=""
  CLOUD_RUN_REVISION=""
}

ensure_state_file() {
  mkdir -p "${STATE_DIR}"
  if [[ ! -f "${STATE_FILE}" ]]; then
    printf '{}\n' > "${STATE_FILE}"
  fi
}

get_state_bool() {
  local key="$1"
  ensure_state_file
  if [[ -z "${PROJECT_ID}" ]] || ! command -v jq >/dev/null 2>&1; then
    printf 'false'
    return 0
  fi
  jq -r --arg pid "${PROJECT_ID}" --arg k "${key}" \
    'if (.[$pid][$k] // false) == true then "true" else "false" end' \
    "${STATE_FILE}" 2>/dev/null || printf 'false'
}

set_state_bool() {
  local key="$1"
  local val="$2"
  ensure_state_file
  if [[ -z "${PROJECT_ID}" ]] || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  local tmp_state
  tmp_state="$(mktemp "${STATE_DIR}/state.XXXXXX")"
  jq --arg pid "${PROJECT_ID}" --arg k "${key}" --argjson v "${val}" \
    '.[$pid] = ((.[$pid] // {}) + {($k): $v})' \
    "${STATE_FILE}" > "${tmp_state}"
  mv "${tmp_state}" "${STATE_FILE}"
}

# ------------------------------------------------------------------------------
# Helpers de API Dataform (leitura autenticada via gcloud)
# ------------------------------------------------------------------------------
API_HTTP_STATUS=""
API_RESPONSE_BODY=""

dataform_get() {
  local url="$1"
  local token
  token="$(gcloud auth print-access-token 2>/dev/null || true)"
  if [[ -z "${token}" ]]; then
    API_HTTP_STATUS="000"
    API_RESPONSE_BODY=""
    return 1
  fi

  local tmp_out
  tmp_out="$(mktemp)"
  API_HTTP_STATUS="$(curl -sS -o "${tmp_out}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    "${url}" || printf '000')"
  unset token
  API_RESPONSE_BODY="$(cat "${tmp_out}")"
  rm -f "${tmp_out}"
  return 0
}

dataform_post() {
  local url="$1"
  local payload="$2"
  local token
  token="$(gcloud auth print-access-token 2>/dev/null || true)"
  if [[ -z "${token}" ]]; then
    API_HTTP_STATUS="000"
    API_RESPONSE_BODY=""
    return 1
  fi

  local tmp_out
  tmp_out="$(mktemp)"
  API_HTTP_STATUS="$(curl -sS -o "${tmp_out}" -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    --data-binary "${payload}" \
    "${url}" || printf '000')"
  unset token
  API_RESPONSE_BODY="$(cat "${tmp_out}")"
  rm -f "${tmp_out}"
  return 0
}

# ------------------------------------------------------------------------------
# GATE 0: Verifica se project.sh, deploy.sh e dataform.sh foram executados
# ------------------------------------------------------------------------------
verify_gate0() {
  section "Verificando Pré-Requisitos Base (project.sh -> deploy.sh -> dataform.sh)"
  local gate0_failures=0

  local req_bin
  for req_bin in gcloud bq jq curl "${PYTHON_BIN}"; do
    if ! command -v "${req_bin}" >/dev/null 2>&1; then
      fail_msg "Ferramenta obrigatória ausente no PATH: ${req_bin}"
      gate0_failures=$((gate0_failures + 1))
    fi
  done
  if [[ "${gate0_failures}" -gt 0 ]]; then
    return 1
  fi

  # 1) Verificação do project.sh
  local project_file_id=""
  if [[ -f "${PROJECT_FILE}" ]]; then
    project_file_id="$(tr -d '[:space:]' < "${PROJECT_FILE}" || true)"
  fi

  if [[ -z "${project_file_id}" ]]; then
    fail_msg "Passo 1 pendente (./project.sh): arquivo '${PROJECT_FILE}' não encontrado ou vazio."
    info_msg "Execute: ./project.sh"
    gate0_failures=$((gate0_failures + 1))
  elif [[ -z "${PROJECT_ID}" ]]; then
    fail_msg "Passo 1 pendente (./project.sh): nenhum PROJECT_ID ativo configurado."
    info_msg "Execute: ./project.sh"
    gate0_failures=$((gate0_failures + 1))
  else
    local lifecycle billing_enabled
    lifecycle="$(gcloud projects describe "${PROJECT_ID}" --format='value(lifecycleState)' 2>/dev/null || true)"
    billing_enabled="$(gcloud billing projects describe "${PROJECT_ID}" --format='value(billingEnabled)' 2>/dev/null || true)"
    if [[ "${lifecycle}" != "ACTIVE" || "${billing_enabled}" != "True" ]]; then
      fail_msg "Passo 1 pendente (./project.sh): projeto '${PROJECT_ID}' inativo (state=${lifecycle:-none}) ou sem billing (billing=${billing_enabled:-false})."
      info_msg "Execute: ./project.sh"
      gate0_failures=$((gate0_failures + 1))
    else
      ok "project.sh verificado: projeto '${PROJECT_ID}' ativo, com billing vinculado (${PROJECT_FILE})."
    fi
  fi

  if [[ "${gate0_failures}" -gt 0 ]]; then
    set_state_bool "gate0_passed" "false"
    return 1
  fi

  # 2) Verificação do deploy.sh
  local service_json=""
  service_json="$(gcloud run services describe "${FUNCTION_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --format=json 2>/dev/null || true)"

  if [[ -z "${service_json}" ]]; then
    fail_msg "Passo 2 pendente (./deploy.sh): serviço Cloud Run '${FUNCTION_NAME}' não encontrado em ${PROJECT_ID}/${REGION}."
    info_msg "Execute: ./deploy.sh"
    gate0_failures=$((gate0_failures + 1))
  else
    CLOUD_RUN_URL="$(printf '%s' "${service_json}" | jq -r '.status.url // ""')"
    CLOUD_RUN_REVISION="$(printf '%s' "${service_json}" | jq -r '.status.latestReadyRevisionName // ""')"
    if [[ -z "${CLOUD_RUN_URL}" || -z "${CLOUD_RUN_REVISION}" ]]; then
      fail_msg "Passo 2 pendente (./deploy.sh): Cloud Run '${FUNCTION_NAME}' sem revisão pronta."
      gate0_failures=$((gate0_failures + 1))
    fi
  fi

  if ! bq --project_id="${PROJECT_ID}" show --dataset "${PROJECT_ID}:${BQ_DATASET}" >/dev/null 2>&1; then
    fail_msg "Passo 2 pendente (./deploy.sh): dataset BigQuery '${PROJECT_ID}:${BQ_DATASET}' não encontrado."
    gate0_failures=$((gate0_failures + 1))
  fi

  if ! bq show --project_id="${PROJECT_ID}" --location="${BQ_LOCATION}" --connection "${BQ_CONNECTION_ID}" >/dev/null 2>&1; then
    fail_msg "Passo 2 pendente (./deploy.sh): conexão BigQuery '${BQ_CONNECTION_ID}' (${BQ_LOCATION}) não encontrada."
    gate0_failures=$((gate0_failures + 1))
  fi

  if ! bq --project_id="${PROJECT_ID}" show --routine "${PROJECT_ID}:${BQ_DATASET}.evaluate_article" >/dev/null 2>&1; then
    fail_msg "Passo 2 pendente (./deploy.sh): Remote Function '${PROJECT_ID}.${BQ_DATASET}.evaluate_article' não encontrada."
    gate0_failures=$((gate0_failures + 1))
  fi

  if [[ "${gate0_failures}" -eq 0 ]]; then
    ok "deploy.sh verificado: Cloud Run (${CLOUD_RUN_REVISION}), conexão e Remote Function ativos."
  else
    info_msg "Execute: ./deploy.sh"
    set_state_bool "gate0_passed" "false"
    return 1
  fi

  # 3) Verificação do dataform.sh
  local repo_resource="projects/${PROJECT_ID}/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPO_ID}"
  local release_resource="${repo_resource}/releaseConfigs/${DATAFORM_RELEASE_CONFIG_ID}"

  dataform_get "${DATAFORM_API_BASE}/${repo_resource}" || true
  if [[ "${API_HTTP_STATUS}" != "200" ]]; then
    fail_msg "Passo 3 pendente (./dataform.sh): repositório Dataform '${DATAFORM_REPO_ID}' não encontrado (HTTP ${API_HTTP_STATUS})."
    info_msg "Execute: ./dataform.sh"
    set_state_bool "gate0_passed" "false"
    return 1
  fi

  dataform_get "${DATAFORM_API_BASE}/${release_resource}" || true
  if [[ "${API_HTTP_STATUS}" != "200" ]]; then
    fail_msg "Passo 3 pendente (./dataform.sh): Release Config '${DATAFORM_RELEASE_CONFIG_ID}' não encontrada no Dataform."
    info_msg "Execute: ./dataform.sh"
    set_state_bool "gate0_passed" "false"
    return 1
  fi

  local rc_db rc_endpoint
  rc_db="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.codeCompilationConfig.defaultDatabase // ""')"
  rc_endpoint="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.codeCompilationConfig.vars.cloudRunEndpoint // ""')"
  if [[ "${rc_db}" != "${PROJECT_ID}" || "${rc_endpoint}" != "${CLOUD_RUN_URL}" ]]; then
    fail_msg "Passo 3 desatualizado (./dataform.sh): Release Config aponta para db='${rc_db}' / endpoint='${rc_endpoint}'."
    info_msg "Reexecute: ./dataform.sh"
    set_state_bool "gate0_passed" "false"
    return 1
  fi

  dataform_get "${DATAFORM_API_BASE}/${repo_resource}/compilationResults?pageSize=5" || true
  local valid_compilations="0"
  if [[ "${API_HTTP_STATUS}" == "200" ]]; then
    valid_compilations="$(printf '%s' "${API_RESPONSE_BODY}" | jq '[.compilationResults[]? | select(((.compilationErrors // []) | length) == 0)] | length')"
  fi

  if [[ "${valid_compilations}" -lt 1 ]]; then
    fail_msg "Passo 3 pendente (./dataform.sh): nenhum resultado de compilação válido encontrado no repositório Dataform."
    info_msg "Execute: ./dataform.sh"
    set_state_bool "gate0_passed" "false"
    return 1
  fi

  ok "dataform.sh verificado: repositório '${DATAFORM_REPO_ID}', release '${DATAFORM_RELEASE_CONFIG_ID}' e compilação sem erros."
  set_state_bool "gate0_passed" "true"
  return 0
}

# ------------------------------------------------------------------------------
# ENUNCIADOS DAS TAREFAS (Exibidos somente quando desbloqueados!)
# ------------------------------------------------------------------------------
print_enunciado_tarefa_1() {
  cat <<'EOF'

==============================================================================
  📋 ENUNCIADO — TAREFA 1: Triagem Editorial Multi-Critério (Decisions API)
==============================================================================

CONTEXTO
--------
Atualmente, a função Cloud Run (`function/main.py`) consulta a Gemini Decisions API
(`gemini-decision-1`) com 3 perguntas em um único forward pass (`category_pred`,
`is_market_moving` e `editorial_urgency`) e define a fila `route` apenas entre
`auto_publish` e `human_review` olhando somente para `category_confidence >= 0.75`.

A redação precisa adicionar uma 4ª dimensão de risco factual e rotear matérias
automaticamente entre 4 filas especializadas, refletindo essa evolução até os
contratos de dados e marts analíticos do Dataform no BigQuery.

O QUE VOCÊ DEVE CONSTRUIR (COM AJUDA DO ANTIGRAVITY CLI `agy`)
--------------------------------------------------------------
1. Cloud Run (`function/main.py`):
   • Adicione a pergunta `requires_fact_check` em `DECISION_QUESTIONS` usando:
     - `"type": "noul"`
     - `"instructions"` avaliando se o artigo traz alegações factuais sensíveis,
       estatísticas/valores financeiros específicos ou acusações legais que exijam
       checagem de fatos antes da publicação.
     - `"criteria"` com `"true_description"` e `"false_description"`.
   • Extraia a resposta no retorno de `evaluate_row` no campo numérico
     `"requires_fact_check_prob"` (arredondado com `round(float(...), 6)`).
   • Inclua `"requires_fact_check_prob": None` no payload de fallback `_error_reply`.
   • Evolua o cálculo de `"route"` respeitando exatamente esta ordem de precedência:
     1) `"human_review"`     se `category_confidence < CONFIDENCE_THRESHOLD` (0.75)
     2) `"fact_check_queue"` se `requires_fact_check_prob >= 0.70`
     3) `"breaking_desk"`    se `editorial_urgency_score >= 2.5` OU `is_market_moving_prob >= 0.80`
     4) `"auto_publish"`     nos demais casos

2. Testes Unitários (`function/tests/test_main.py`):
   • Atualize os mocks da Decisions API para retornar `requires_fact_check` e crie
     testes cobrindo as 4 rotas (`human_review`, `fact_check_queue`, `breaking_desk`,
     `auto_publish`) e o fallback de erro.

3. Pipeline Dataform (`definitions/`):
   • Em `definitions/staging/bbc_news_decisions_50.sqlx`, atualize a assertion
     `rowConditions` para aceitar as 4 rotas válidas:
     `('auto_publish', 'breaking_desk', 'fact_check_queue', 'human_review')`.
   • Em `definitions/marts/eval_routing_summary.sqlx`, adicione a coluna
     `avg_fact_check_prob` calculando a média arredondada de `requires_fact_check_prob`.
   • Crie uma nova view `definitions/marts/fact_check_priority_queue.sqlx` lendo de
     `${ref("bbc_news_decisions_50")}`, expondo `title`, `actual_category`,
     `category_pred`, `requires_fact_check_prob`, `editorial_urgency_score` e `route`,
     ordenada por `requires_fact_check_prob DESC`.

4. Convenções do Repositório (`AGENTS.md`):
   • Registre as adições e mudanças na seção `## [Unreleased]` do `CHANGELOG.md`.

DICA DE USO NO ANTIGRAVITY CLI (`agy`)
--------------------------------------
Abra o `agy` neste diretório, use `/plan` passando os requisitos acima para revisar
o plano multi-arquivo (Python + Testes + SQLX + Changelog) e peça ao agente para
validar localmente com `./scripts/verify_security.sh`.

COMO FAZER O DEPLOY E DESTRAVAR A TAREFA 2
------------------------------------------
Após validar localmente, publique a nova revisão do Cloud Run e materialize os
novos itens do Dataform no BigQuery usando os scripts existentes:

  ./deploy.sh -q
  ./dataform.sh -q --run

(Ou use o atalho equivalente: `./workshop.sh deploy -q`)

Em seguida, valide sua entrega para liberar a Tarefa 2:

  ./workshop.sh validate
==============================================================================
EOF
}

print_enunciado_tarefa_2() {
  cat <<'EOF'

==============================================================================
  📋 ENUNCIADO — TAREFA 2: Telemetria de Latência, Matriz de Confusão & Report
==============================================================================

CONTEXTO
--------
Com a triagem editorial de 4 filas operando em produção, a equipe de engenharia
precisa medir a latência real por artigo (`latency_ms`) da Gemini Decisions API,
diagnosticar quais categorias de notícias o modelo mais confunde entre si e ter um
painel executivo direto no terminal para inspecionar o benchmark sem abrir o console.

O QUE VOCÊ DEVE CONSTRUIR (COM AJUDA DO ANTIGRAVITY CLI `agy`)
--------------------------------------------------------------
1. Telemetria no Cloud Run (`function/main.py` + `function/tests/test_main.py`):
   • Em `evaluate_row`, meça a duração da chamada à Decisions API com
     `time.perf_counter()` e retorne `"latency_ms"` (float >= 0 em milissegundos,
     ex.: `round(..., 2)`) no dicionário de resposta (mantendo todos os campos da
     Tarefa 1!).
   • Em `_error_reply`, inclua `"latency_ms": None`.
   • Adicione/atualize os testes unitários em `function/tests/test_main.py`
     garantindo a presença e o tipo numérico de `latency_ms`.

2. Novos Marts Analíticos no Dataform (`definitions/marts/`):
   • Crie `definitions/marts/eval_latency_stats.sqlx` (type: `"view"`):
     - Lê de `${ref("bbc_news_decisions_50")}` usando `SAFE.FLOAT64(decision.latency_ms)`.
     - Calcula métricas de latência (`avg_latency_ms`, `p50_latency_ms`,
       `p95_latency_ms`, `max_latency_ms`) agrupadas por categoria (ou com `ROLLUP`).
   • Crie `definitions/marts/eval_confusion_matrix.sqlx` (type: `"view"`):
     - Lê de `${ref("bbc_news_decisions_50")}`.
     - Agrupa por `actual_category` e `JSON_VALUE(decision, '$.category_pred') AS category_pred`,
       exibindo `article_count` e `share_pct` para revelar confusões entre classes.

3. CLI de Relatório Executivo (`scripts/report.sh`):
   • Crie o script executável `scripts/report.sh` (`chmod +x`), seguindo os padrões
     de segurança do projeto (`#!/usr/bin/env bash`, `set -euo pipefail`, `umask 077`,
     aprovado pelo `shellcheck`).
   • Suporte as flags:
     - `--help` / `-h`: exibe instruções de uso e retorna código 0.
     - `--offline`: imprime uma prévia demonstrativa formatada no terminal sem exigir
       chamadas ao GCP (útil para testes rápidos e CI).
     - Execução padrão (sem `--offline`): consulta via `bq query` os marts do dataset
       (`${PROJECT_ID}.${BQ_DATASET}`: acurácia, filas de roteamento, estatísticas de
       latência e matriz de confusão) e imprime o relatório consolidado no terminal.

4. Convenções do Repositório (`AGENTS.md`):
   • Atualize `CHANGELOG.md` na seção `## [Unreleased]` e garanta aprovação total em
     `./scripts/verify_security.sh`.

COMO FAZER O DEPLOY E CONCLUIR O WORKSHOP
-----------------------------------------
Publique a nova versão do Cloud Run e sincronize/execute os novos marts no Dataform:

  ./deploy.sh -q
  ./dataform.sh -q --run

(Ou use o atalho equivalente: `./workshop.sh deploy -q`)

Em seguida, execute a validação final do workshop:

  ./workshop.sh validate
==============================================================================
EOF
}

# ------------------------------------------------------------------------------
# GATE 1: Validação Completa da Tarefa 1 (Local + Cloud Run + Dataform/BigQuery)
# ------------------------------------------------------------------------------
validate_task1() {
  banner "Validando Tarefa 1 — Triagem Editorial Multi-Critério"
  local failures=0

  # [1/6] Validação comportamental Python de function/main.py
  section "[1/6] Código & Regras de Roteamento em function/main.py"
  if "${PYTHON_BIN}" - "${FUNCTION_DIR}" <<'PY'
from contextlib import nullcontext
import json
from pathlib import Path
import sys
import types
from unittest.mock import MagicMock

func_dir = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(func_dir))

try:
    import flask  # noqa: F401
except ModuleNotFoundError:
    flask_stub = types.ModuleType("flask")
    flask_stub.Response = object
    flask_stub.Request = object
    flask_stub.Flask = lambda _name: types.SimpleNamespace(app_context=nullcontext)
    flask_stub.jsonify = lambda payload: payload
    sys.modules["flask"] = flask_stub

try:
    import functions_framework  # noqa: F401
except ModuleNotFoundError:
    ff_stub = types.ModuleType("functions_framework")
    ff_stub.http = lambda fn: fn
    sys.modules["functions_framework"] = ff_stub

try:
    from google import genai  # noqa: F401
except ModuleNotFoundError:
    google_mod = types.ModuleType("google")
    google_mod.__path__ = []
    genai_mod = types.ModuleType("google.genai")
    genai_mod.Client = MagicMock
    google_mod.genai = genai_mod
    sys.modules["google"] = google_mod
    sys.modules["google.genai"] = genai_mod

import main  # noqa: E402

q = main.DECISION_QUESTIONS.get("requires_fact_check")
assert isinstance(q, dict), "Pergunta 'requires_fact_check' ausente em DECISION_QUESTIONS."
assert q.get("type") == "noul", "requires_fact_check deve ter 'type': 'noul'."
criteria = q.get("criteria", {})
assert "true_description" in criteria and "false_description" in criteria, (
    "requires_fact_check.criteria deve conter 'true_description' e 'false_description'."
)

err_payload = main._error_reply("boom")
assert "requires_fact_check_prob" in err_payload and err_payload["requires_fact_check_prob"] is None, (
    "_error_reply deve incluir 'requires_fact_check_prob': None."
)

def run_case(conf: float, market: float, urgency: float, fact_check: float) -> dict:
    fake_client = MagicMock()
    fake_client.decisions.create.return_value = types.SimpleNamespace(
        answers={
            "category_pred": types.SimpleNamespace(choice="business", confidence=conf),
            "is_market_moving": types.SimpleNamespace(noul=market),
            "editorial_urgency": types.SimpleNamespace(score=urgency),
            "requires_fact_check": types.SimpleNamespace(noul=fact_check),
        }
    )
    orig_get = main.get_genai_client
    main.get_genai_client = lambda: fake_client
    try:
        return main.evaluate_row(["Headline", "Body text"], 0, "req-1")
    finally:
        main.get_genai_client = orig_get

r_low_conf = run_case(conf=0.60, market=0.95, urgency=3.0, fact_check=0.95)
assert r_low_conf.get("route") == "human_review", (
    f"Esperado 'human_review' para confidence=0.60, obteve {r_low_conf.get('route')!r}"
)

r_fact = run_case(conf=0.90, market=0.95, urgency=2.8, fact_check=0.75)
assert r_fact.get("route") == "fact_check_queue", (
    f"Esperado 'fact_check_queue' para requires_fact_check_prob=0.75, obteve {r_fact.get('route')!r}"
)
assert isinstance(r_fact.get("requires_fact_check_prob"), (int, float)), (
    "Campo 'requires_fact_check_prob' deve ser numérico."
)

r_breaking_urg = run_case(conf=0.90, market=0.20, urgency=2.6, fact_check=0.20)
assert r_breaking_urg.get("route") == "breaking_desk", (
    f"Esperado 'breaking_desk' para urgency=2.6, obteve {r_breaking_urg.get('route')!r}"
)

r_breaking_mkt = run_case(conf=0.90, market=0.85, urgency=1.0, fact_check=0.20)
assert r_breaking_mkt.get("route") == "breaking_desk", (
    f"Esperado 'breaking_desk' para market_moving=0.85, obteve {r_breaking_mkt.get('route')!r}"
)

r_auto = run_case(conf=0.92, market=0.20, urgency=1.0, fact_check=0.20)
assert r_auto.get("route") == "auto_publish", (
    f"Esperado 'auto_publish' para artigo rotineiro de alta confiança, obteve {r_auto.get('route')!r}"
)
print(json.dumps({"status": "ok"}))
PY
  then
    ok "DECISION_QUESTIONS, requires_fact_check_prob e precedência das 4 rotas validados."
  else
    fail_msg "Validação funcional de function/main.py falhou para os critérios da Tarefa 1."
    failures=$((failures + 1))
  fi

  # [2/6] Arquivos locais do Dataform
  section "[2/6] Definições SQLX do Dataform"
  local staging_sqlx="${DEFINITIONS_DIR}/staging/bbc_news_decisions_50.sqlx"
  local routing_sqlx="${DEFINITIONS_DIR}/marts/eval_routing_summary.sqlx"
  local queue_sqlx="${DEFINITIONS_DIR}/marts/fact_check_priority_queue.sqlx"

  if grep -Fq "fact_check_queue" "${staging_sqlx}" && grep -Fq "breaking_desk" "${staging_sqlx}"; then
    ok "Assertions atualizadas em definitions/staging/bbc_news_decisions_50.sqlx."
  else
    fail_msg "definitions/staging/bbc_news_decisions_50.sqlx deve incluir 'fact_check_queue' e 'breaking_desk' nas assertions."
    failures=$((failures + 1))
  fi

  if grep -Fq "requires_fact_check_prob" "${routing_sqlx}"; then
    ok "Métrica requires_fact_check_prob adicionada em definitions/marts/eval_routing_summary.sqlx."
  else
    fail_msg "definitions/marts/eval_routing_summary.sqlx deve agregar 'requires_fact_check_prob'."
    failures=$((failures + 1))
  fi

  if [[ -f "${queue_sqlx}" ]] \
    && grep -Fq "bbc_news_decisions_50" "${queue_sqlx}" \
    && grep -Fq "requires_fact_check_prob" "${queue_sqlx}"; then
    ok "Novo mart definitions/marts/fact_check_priority_queue.sqlx encontrado e válido."
  else
    fail_msg "Crie definitions/marts/fact_check_priority_queue.sqlx consultando bbc_news_decisions_50 e requires_fact_check_prob."
    failures=$((failures + 1))
  fi

  # [3/6] CHANGELOG.md (AGENTS.md)
  section "[3/6] Convenções de Documentação (CHANGELOG.md)"
  if grep -Fqi "requires_fact_check" "${SCRIPT_DIR}/CHANGELOG.md" || grep -Fqi "fact_check_queue" "${SCRIPT_DIR}/CHANGELOG.md"; then
    ok "CHANGELOG.md atualizado com as mudanças da Tarefa 1."
  else
    fail_msg "Atualize a seção [Unreleased] do CHANGELOG.md documentando a Tarefa 1 (conforme AGENTS.md)."
    failures=$((failures + 1))
  fi

  # [4/6] Suíte offline de segurança e testes unitários
  section "[4/6] Testes Unitários & Segurança Offline (./scripts/verify_security.sh)"
  if "${SCRIPT_DIR}/scripts/verify_security.sh"; then
    ok "Todos os testes unitários e verificações de segurança passaram."
  else
    fail_msg "./scripts/verify_security.sh reportou falhas. Corrija antes de avançar."
    failures=$((failures + 1))
  fi

  if [[ "${failures}" -gt 0 ]]; then
    fail_msg "Corrija os itens locais acima, publique com './deploy.sh -q && ./dataform.sh -q --run' e rode './workshop.sh validate'."
    return 1
  fi

  # [5/6] Cloud Run + BigQuery Remote Function (Live Probe)
  section "[5/6] Nova Versão Publicada no Cloud Run (Live Probe via BigQuery)"
  local probe_json=""
  probe_json="$(bq query \
    --project_id="${PROJECT_ID}" \
    --location="${BQ_LOCATION}" \
    --use_legacy_sql=false \
    --format=json \
    "SELECT TO_JSON_STRING(\`${PROJECT_ID}.${BQ_DATASET}.evaluate_article\`('Quarterly earnings investigation', 'Regulators opened an inquiry into disputed revenue figures reported by the bank.')) AS payload" 2>/dev/null || true)"

  local parsed_payload=""
  parsed_payload="$(printf '%s' "${probe_json}" | jq -r '.[0].payload // ""' 2>/dev/null || true)"

  if [[ -n "${parsed_payload}" ]] && printf '%s' "${parsed_payload}" | jq -e '
    (.error == null)
    and ((.requires_fact_check_prob | type) == "number")
    and (.route == "auto_publish" or .route == "breaking_desk" or .route == "fact_check_queue" or .route == "human_review")
  ' >/dev/null 2>&1; then
    ok "Cloud Run em produção respondeu com requires_fact_check_prob e fila '${parsed_payload}'."
  else
    fail_msg "A revisão publicada no Cloud Run ainda não retornou 'requires_fact_check_prob' válido."
    info_msg "Publique a nova revisão da função executando: ./deploy.sh -q"
    failures=$((failures + 1))
  fi

  # [6/6] Dataform & Materialização no BigQuery
  section "[6/6] Sincronização Dataform & Views Materializadas no BigQuery"
  local repo_resource="projects/${PROJECT_ID}/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPO_ID}"
  local release_resource="${repo_resource}/releaseConfigs/${DATAFORM_RELEASE_CONFIG_ID}"
  local compile_payload
  compile_payload="$(jq -n --arg rc "${release_resource}" '{releaseConfig: $rc}')"

  dataform_post "${DATAFORM_API_BASE}/${repo_resource}/compilationResults" "${compile_payload}" || true
  local comp_name=""
  if [[ "${API_HTTP_STATUS}" =~ ^2[0-9][0-9]$ ]]; then
    local comp_errs
    comp_errs="$(printf '%s' "${API_RESPONSE_BODY}" | jq '(.compilationErrors // []) | length')"
    comp_name="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.name // ""')"
    if [[ "${comp_errs}" -gt 0 ]]; then
      fail_msg "O repositório Dataform remoto apresentou ${comp_errs} erro(s) de compilação."
      failures=$((failures + 1))
      comp_name=""
    fi
  else
    fail_msg "Não foi possível validar a compilação remota do Dataform (HTTP ${API_HTTP_STATUS})."
    failures=$((failures + 1))
  fi

  if [[ -n "${comp_name}" ]]; then
    dataform_get "${DATAFORM_API_BASE}/${comp_name}:query?pageSize=100" || true
    if [[ "${API_HTTP_STATUS}" == "200" ]] && printf '%s' "${API_RESPONSE_BODY}" | jq -e '
      [.compilationResultActions[]?.target.name] | index("fact_check_priority_queue") != null
    ' >/dev/null 2>&1; then
      ok "Mart 'fact_check_priority_queue' sincronizado e compilado no repositório Dataform."
    else
      fail_msg "O mart 'fact_check_priority_queue' ainda não consta no repositório Dataform remoto."
      info_msg "Sincronize e execute no Dataform com: ./dataform.sh -q --run"
      failures=$((failures + 1))
    fi
  fi

  if bq --project_id="${PROJECT_ID}" show "${PROJECT_ID}:${BQ_DATASET}.fact_check_priority_queue" >/dev/null 2>&1; then
    local non_null_fc="0"
    non_null_fc="$(bq query \
      --project_id="${PROJECT_ID}" \
      --location="${BQ_LOCATION}" \
      --use_legacy_sql=false \
      --format=json \
      "SELECT COUNTIF(SAFE.FLOAT64(decision.requires_fact_check_prob) IS NOT NULL) AS cnt FROM \`${PROJECT_ID}.${BQ_DATASET}.bbc_news_decisions_50\`" 2>/dev/null \
      | jq -r '.[0].cnt // "0"' 2>/dev/null || printf '0')"
    if [[ "${non_null_fc}" -gt 0 ]]; then
      ok "Tabela bbc_news_decisions_50 (${non_null_fc} linhas com requires_fact_check_prob) e view fact_check_priority_queue ativas no BigQuery."
    else
      fail_msg "A tabela bbc_news_decisions_50 no BigQuery ainda não contém 'requires_fact_check_prob' populado."
      info_msg "Reexecute o pipeline Dataform com: ./dataform.sh -q --run"
      failures=$((failures + 1))
    fi
  else
    fail_msg "A view '${PROJECT_ID}:${BQ_DATASET}.fact_check_priority_queue' ainda não foi materializada no BigQuery."
    info_msg "Execute o pipeline Dataform com: ./dataform.sh -q --run"
    failures=$((failures + 1))
  fi

  if [[ "${failures}" -gt 0 ]]; then
    return 1
  fi

  set_state_bool "task1_passed" "true"
  return 0
}

# ------------------------------------------------------------------------------
# GATE 2: Validação Completa da Tarefa 2 (Local + Cloud Run + Dataform + CLI)
# ------------------------------------------------------------------------------
validate_task2() {
  banner "Validando Tarefa 2 — Telemetria de Latência, Matriz de Confusão & Report"
  local failures=0

  # [1/6] Validação comportamental Python de latency_ms em function/main.py
  section "[1/6] Telemetria latency_ms em function/main.py"
  if "${PYTHON_BIN}" - "${FUNCTION_DIR}" <<'PY'
from contextlib import nullcontext
import json
from pathlib import Path
import sys
import types
from unittest.mock import MagicMock

func_dir = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(func_dir))

try:
    import flask  # noqa: F401
except ModuleNotFoundError:
    flask_stub = types.ModuleType("flask")
    flask_stub.Response = object
    flask_stub.Request = object
    flask_stub.Flask = lambda _name: types.SimpleNamespace(app_context=nullcontext)
    flask_stub.jsonify = lambda payload: payload
    sys.modules["flask"] = flask_stub

try:
    import functions_framework  # noqa: F401
except ModuleNotFoundError:
    ff_stub = types.ModuleType("functions_framework")
    ff_stub.http = lambda fn: fn
    sys.modules["functions_framework"] = ff_stub

try:
    from google import genai  # noqa: F401
except ModuleNotFoundError:
    google_mod = types.ModuleType("google")
    google_mod.__path__ = []
    genai_mod = types.ModuleType("google.genai")
    genai_mod.Client = MagicMock
    google_mod.genai = genai_mod
    sys.modules["google"] = google_mod
    sys.modules["google.genai"] = genai_mod

import main  # noqa: E402

err_payload = main._error_reply("timeout")
assert "latency_ms" in err_payload, "_error_reply deve incluir a chave 'latency_ms'."

fake_client = MagicMock()
fake_client.decisions.create.return_value = types.SimpleNamespace(
    answers={
        "category_pred": types.SimpleNamespace(choice="tech", confidence=0.93),
        "is_market_moving": types.SimpleNamespace(noul=0.15),
        "editorial_urgency": types.SimpleNamespace(score=1.0),
        "requires_fact_check": types.SimpleNamespace(noul=0.10),
    }
)
orig_get = main.get_genai_client
main.get_genai_client = lambda: fake_client
try:
    row = main.evaluate_row(["New chip launch", "Tech company unveils processor."], 0, "req-2")
finally:
    main.get_genai_client = orig_get

assert "latency_ms" in row and isinstance(row["latency_ms"], (int, float)) and row["latency_ms"] >= 0, (
    f"evaluate_row deve retornar 'latency_ms' numérico >= 0, obteve: {row.get('latency_ms')!r}"
)
assert "requires_fact_check_prob" in row, "Não remova 'requires_fact_check_prob' implementado na Tarefa 1."
print(json.dumps({"status": "ok"}))
PY
  then
    ok "Medição de latency_ms e compatibilidade com Tarefa 1 validadas em function/main.py."
  else
    fail_msg "Validação funcional de latency_ms em function/main.py falhou."
    failures=$((failures + 1))
  fi

  # [2/6] Novos marts locais do Dataform
  section "[2/6] Marts Analíticos no Dataform (eval_latency_stats & eval_confusion_matrix)"
  local latency_sqlx="${DEFINITIONS_DIR}/marts/eval_latency_stats.sqlx"
  local matrix_sqlx="${DEFINITIONS_DIR}/marts/eval_confusion_matrix.sqlx"

  if [[ -f "${latency_sqlx}" ]] \
    && grep -Fq "bbc_news_decisions_50" "${latency_sqlx}" \
    && grep -Fq "latency_ms" "${latency_sqlx}"; then
    ok "definitions/marts/eval_latency_stats.sqlx encontrado e referenciando latency_ms."
  else
    fail_msg "Crie definitions/marts/eval_latency_stats.sqlx calculando métricas de latency_ms sobre bbc_news_decisions_50."
    failures=$((failures + 1))
  fi

  if [[ -f "${matrix_sqlx}" ]] \
    && grep -Fq "bbc_news_decisions_50" "${matrix_sqlx}" \
    && grep -Fq "actual_category" "${matrix_sqlx}" \
    && grep -Fq "category_pred" "${matrix_sqlx}"; then
    ok "definitions/marts/eval_confusion_matrix.sqlx encontrado e cruzando actual_category x category_pred."
  else
    fail_msg "Crie definitions/marts/eval_confusion_matrix.sqlx cruzando actual_category e category_pred."
    failures=$((failures + 1))
  fi

  # [3/6] CLI scripts/report.sh + CHANGELOG.md
  section "[3/6] CLI de Relatório Executivo (scripts/report.sh) & CHANGELOG.md"
  local report_script="${SCRIPT_DIR}/scripts/report.sh"
  if [[ ! -f "${report_script}" ]]; then
    fail_msg "Script scripts/report.sh não encontrado."
    failures=$((failures + 1))
  elif [[ ! -x "${report_script}" ]]; then
    fail_msg "scripts/report.sh precisa ter permissão de execução (chmod +x scripts/report.sh)."
    failures=$((failures + 1))
  else
    if ! bash -n "${report_script}"; then
      fail_msg "Erro de sintaxe Bash em scripts/report.sh."
      failures=$((failures + 1))
    elif command -v shellcheck >/dev/null 2>&1 && ! shellcheck "${report_script}"; then
      fail_msg "shellcheck apontou avisos em scripts/report.sh."
      failures=$((failures + 1))
    elif ! "${report_script}" --help >/dev/null 2>&1; then
      fail_msg "scripts/report.sh --help falhou."
      failures=$((failures + 1))
    elif ! "${report_script}" --offline >/dev/null 2>&1; then
      fail_msg "scripts/report.sh --offline falhou."
      failures=$((failures + 1))
    else
      ok "scripts/report.sh executável, aprovado no shellcheck e com --help / --offline funcionais."
    fi
  fi

  if grep -Fqi "latency_ms" "${SCRIPT_DIR}/CHANGELOG.md" || grep -Fqi "report.sh" "${SCRIPT_DIR}/CHANGELOG.md"; then
    ok "CHANGELOG.md atualizado com as entregas da Tarefa 2."
  else
    fail_msg "Atualize a seção [Unreleased] do CHANGELOG.md documentando a Tarefa 2."
    failures=$((failures + 1))
  fi

  # [4/6] Suíte offline de segurança e testes unitários
  section "[4/6] Testes Unitários & Segurança Offline (./scripts/verify_security.sh)"
  if "${SCRIPT_DIR}/scripts/verify_security.sh"; then
    ok "Todos os testes unitários e verificações de segurança passaram."
  else
    fail_msg "./scripts/verify_security.sh reportou falhas."
    failures=$((failures + 1))
  fi

  if [[ "${failures}" -gt 0 ]]; then
    fail_msg "Corrija os itens locais acima, publique com './deploy.sh -q && ./dataform.sh -q --run' e rode './workshop.sh validate'."
    return 1
  fi

  # [5/6] Cloud Run + BigQuery Remote Function (Live Probe latency_ms)
  section "[5/6] Nova Versão Publicada no Cloud Run (Live Probe latency_ms)"
  local probe_json=""
  probe_json="$(bq query \
    --project_id="${PROJECT_ID}" \
    --location="${BQ_LOCATION}" \
    --use_legacy_sql=false \
    --format=json \
    "SELECT TO_JSON_STRING(\`${PROJECT_ID}.${BQ_DATASET}.evaluate_article\`('Tech summit opens', 'Engineers gather to benchmark low-latency AI classification pipelines.')) AS payload" 2>/dev/null || true)"

  local parsed_payload=""
  parsed_payload="$(printf '%s' "${probe_json}" | jq -r '.[0].payload // ""' 2>/dev/null || true)"

  if [[ -n "${parsed_payload}" ]] && printf '%s' "${parsed_payload}" | jq -e '
    (.error == null)
    and ((.latency_ms | type) == "number")
    and (.latency_ms >= 0)
    and ((.requires_fact_check_prob | type) == "number")
  ' >/dev/null 2>&1; then
    ok "Cloud Run em produção respondeu com latency_ms e requires_fact_check_prob: ${parsed_payload}"
  else
    fail_msg "A revisão publicada no Cloud Run ainda não retornou 'latency_ms' numérico."
    info_msg "Publique a nova revisão da função executando: ./deploy.sh -q"
    failures=$((failures + 1))
  fi

  # [6/6] Dataform, Views no BigQuery & Execução Real de scripts/report.sh
  section "[6/6] Dataform, Views no BigQuery & Execução do Relatório"
  local repo_resource="projects/${PROJECT_ID}/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPO_ID}"
  local release_resource="${repo_resource}/releaseConfigs/${DATAFORM_RELEASE_CONFIG_ID}"
  local compile_payload
  compile_payload="$(jq -n --arg rc "${release_resource}" '{releaseConfig: $rc}')"

  dataform_post "${DATAFORM_API_BASE}/${repo_resource}/compilationResults" "${compile_payload}" || true
  local comp_name=""
  if [[ "${API_HTTP_STATUS}" =~ ^2[0-9][0-9]$ ]]; then
    local comp_errs
    comp_errs="$(printf '%s' "${API_RESPONSE_BODY}" | jq '(.compilationErrors // []) | length')"
    comp_name="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.name // ""')"
    if [[ "${comp_errs}" -gt 0 ]]; then
      fail_msg "O repositório Dataform remoto apresentou ${comp_errs} erro(s) de compilação."
      failures=$((failures + 1))
      comp_name=""
    fi
  else
    fail_msg "Não foi possível validar a compilação remota do Dataform (HTTP ${API_HTTP_STATUS})."
    failures=$((failures + 1))
  fi

  if [[ -n "${comp_name}" ]]; then
    dataform_get "${DATAFORM_API_BASE}/${comp_name}:query?pageSize=100" || true
    if [[ "${API_HTTP_STATUS}" == "200" ]] && printf '%s' "${API_RESPONSE_BODY}" | jq -e '
      ([.compilationResultActions[]?.target.name]) as $names
      | ($names | index("eval_latency_stats") != null)
      and ($names | index("eval_confusion_matrix") != null)
    ' >/dev/null 2>&1; then
      ok "Marts 'eval_latency_stats' e 'eval_confusion_matrix' sincronizados e compilados no Dataform."
    else
      fail_msg "Os marts 'eval_latency_stats' e/ou 'eval_confusion_matrix' ainda não constam no Dataform remoto."
      info_msg "Sincronize e execute no Dataform com: ./dataform.sh -q --run"
      failures=$((failures + 1))
    fi
  fi

  if bq --project_id="${PROJECT_ID}" show "${PROJECT_ID}:${BQ_DATASET}.eval_latency_stats" >/dev/null 2>&1 \
    && bq --project_id="${PROJECT_ID}" show "${PROJECT_ID}:${BQ_DATASET}.eval_confusion_matrix" >/dev/null 2>&1; then
    local non_null_lat="0"
    non_null_lat="$(bq query \
      --project_id="${PROJECT_ID}" \
      --location="${BQ_LOCATION}" \
      --use_legacy_sql=false \
      --format=json \
      "SELECT COUNTIF(SAFE.FLOAT64(decision.latency_ms) IS NOT NULL) AS cnt FROM \`${PROJECT_ID}.${BQ_DATASET}.bbc_news_decisions_50\`" 2>/dev/null \
      | jq -r '.[0].cnt // "0"' 2>/dev/null || printf '0')"
    if [[ "${non_null_lat}" -gt 0 ]]; then
      ok "Views eval_latency_stats e eval_confusion_matrix ativas (${non_null_lat} linhas com latency_ms)."
    else
      fail_msg "A tabela bbc_news_decisions_50 ainda não possui 'latency_ms' populado."
      info_msg "Reexecute o pipeline Dataform com: ./dataform.sh -q --run"
      failures=$((failures + 1))
    fi
  else
    fail_msg "As views 'eval_latency_stats' e/ou 'eval_confusion_matrix' ainda não foram materializadas no BigQuery."
    info_msg "Execute o pipeline Dataform com: ./dataform.sh -q --run"
    failures=$((failures + 1))
  fi

  if [[ "${failures}" -eq 0 ]]; then
    info_msg "Executando ./scripts/report.sh contra o BigQuery..."
    if PROJECT_ID="${PROJECT_ID}" BQ_DATASET="${BQ_DATASET}" BQ_LOCATION="${BQ_LOCATION}" "${report_script}"; then
      ok "Relatório executivo ./scripts/report.sh executado com sucesso!"
    else
      fail_msg "A execução ao vivo de ./scripts/report.sh falhou."
      failures=$((failures + 1))
    fi
  fi

  if [[ "${failures}" -gt 0 ]]; then
    return 1
  fi

  set_state_bool "task2_passed" "true"
  return 0
}

# ------------------------------------------------------------------------------
# Painel de Progresso e Fluxo Principal
# ------------------------------------------------------------------------------
print_scoreboard() {
  local g0="$1"
  local t1="$2"
  local t2="$3"

  banner "Missão Antigravity CLI: Inteligência Editorial em Escala no Google Cloud"
  printf '  Projeto GCP : %s\n' "${PROJECT_ID:-(não configurado)}"

  if [[ "${g0}" == "true" ]]; then
    done_msg "Etapa 0 — Ambiente Base (project.sh + deploy.sh + dataform.sh)"
  else
    locked_msg "Etapa 0 — Ambiente Base (execute ./project.sh, ./deploy.sh e ./dataform.sh)"
  fi

  if [[ "${g0}" != "true" ]]; then
    locked_msg "Tarefa 1 — [BLOQUEADA: conclua o Ambiente Base primeiro]"
    locked_msg "Tarefa 2 — [BLOQUEADA: conclua a Tarefa 1 primeiro]"
    return 0
  fi

  if [[ "${t1}" == "true" ]]; then
    done_msg "Tarefa 1 — Triagem Editorial Multi-Critério (requires_fact_check + 4 filas)"
  else
    unlocked_msg "Tarefa 1 — Triagem Editorial Multi-Critério (em andamento)"
  fi

  if [[ "${t1}" != "true" ]]; then
    locked_msg "Tarefa 2 — [BLOQUEADA: valide a Tarefa 1 com './workshop.sh validate' para liberar]"
    return 0
  fi

  if [[ "${t2}" == "true" ]]; then
    done_msg "Tarefa 2 — Telemetria de Latência, Matriz de Confusão & CLI Report"
  else
    unlocked_msg "Tarefa 2 — Telemetria de Latência, Matriz de Confusão & CLI Report (em andamento)"
  fi
}

print_completion_certificate() {
  cat <<EOF

==============================================================================
  🏆 PARABÉNS! WORKSHOP ANTIGRAVITY CLI CONCLUÍDO COM SUCESSO!
==============================================================================
  Projeto validado : ${PROJECT_ID}
  Etapa 0          : Infraestrutura Cloud Run + BigQuery + Dataform [OK]
  Tarefa 1         : Triagem Multi-Critério (requires_fact_check)   [OK]
  Tarefa 2         : Latência, Matriz de Confusão & scripts/report  [OK]

  Lembrete de custos: ao encerrar seus testes no GCP, consulte a seção
  "Cleanup" do README.md para remover os recursos provisionados.
==============================================================================
EOF
}

cmd_status() {
  local g0 t1 t2
  g0="$(get_state_bool "gate0_passed")"
  if [[ "${g0}" != "true" ]]; then
    if verify_gate0; then
      g0="true"
    else
      g0="false"
    fi
  fi

  t1="$(get_state_bool "task1_passed")"
  t2="$(get_state_bool "task2_passed")"

  print_scoreboard "${g0}" "${t1}" "${t2}"

  if [[ "${g0}" != "true" ]]; then
    cat <<'EOF'

Próximos passos para liberar a Tarefa 1:
  1. ./project.sh       (cria/vincula o projeto GCP com billing)
  2. ./deploy.sh        (provisiona Cloud Run, Secret Manager e BigQuery Remote Function)
  3. ./dataform.sh      (configura e compila o repositório Dataform)
  4. ./workshop.sh      (verifica os 3 passos acima e libera o enunciado da Tarefa 1)
EOF
    exit 1
  fi

  if [[ "${t1}" != "true" ]]; then
    print_enunciado_tarefa_1
    return 0
  fi

  if [[ "${t2}" != "true" ]]; then
    print_enunciado_tarefa_2
    return 0
  fi

  print_completion_certificate
}

cmd_validate() {
  if ! verify_gate0; then
    print_scoreboard "false" "false" "false"
    exit 1
  fi

  local t1
  t1="$(get_state_bool "task1_passed")"

  if [[ "${t1}" != "true" ]]; then
    if validate_task1; then
      print_scoreboard "true" "true" "false"
      printf '\n  🎉 Tarefa 1 aprovada! A Tarefa 2 acaba de ser desbloqueada:\n'
      print_enunciado_tarefa_2
      return 0
    else
      print_scoreboard "true" "false" "false"
      exit 1
    fi
  fi

  if validate_task2; then
    print_scoreboard "true" "true" "true"
    print_completion_certificate
    return 0
  else
    print_scoreboard "true" "true" "false"
    exit 1
  fi
}

cmd_deploy() {
  banner "Deploy Incremental do Workshop (Segurança -> Cloud Run -> Dataform)"

  section "Passo 1/3: Validação Offline de Segurança e Testes (./scripts/verify_security.sh)"
  "${SCRIPT_DIR}/scripts/verify_security.sh"

  section "Passo 2/3: Atualizando Revisão do Cloud Run e Remote Function (./deploy.sh)"
  if [[ ${#DEPLOY_ARGS[@]} -gt 0 ]]; then
    "${SCRIPT_DIR}/deploy.sh" "${DEPLOY_ARGS[@]}"
  else
    "${SCRIPT_DIR}/deploy.sh"
  fi

  section "Passo 3/3: Sincronizando, Compilando e Executando Dataform (./dataform.sh --run)"
  if [[ ${#DEPLOY_ARGS[@]} -gt 0 ]]; then
    "${SCRIPT_DIR}/dataform.sh" --run "${DEPLOY_ARGS[@]}"
  else
    "${SCRIPT_DIR}/dataform.sh" --run
  fi

  banner "Deploy Incremental Concluído!"
  info_msg "Agora execute './workshop.sh validate' para validar sua tarefa e avançar."
}

cmd_reset() {
  rm -rf "${STATE_DIR}"
  ok "Estado local do workshop (.workshop/) removido. Execute './workshop.sh' para revalidar."
}

main() {
  parse_args "$@"
  load_config

  case "${SUBCOMMAND}" in
    status)
      cmd_status
      ;;
    validate)
      cmd_validate
      ;;
    deploy)
      cmd_deploy
      ;;
    reset)
      cmd_reset
      ;;
  esac
}

main "$@"
