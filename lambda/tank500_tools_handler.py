"""
Tank 500 Tools Lambda Handler for AgentCore Gateway.

Handles tool calls routed from AgentCore Gateway (docs/design.md §2.1):
- retrieve_tank500_info: Query Bedrock Knowledge Base (owner's manual)
- compare_competitor:    Preset competitor catalog, fallback to Tavily web search
- web_search:            Tavily Search API (key from SSM SecureString)
- book_test_drive:       Write a sales lead JSON to S3 leads/ prefix (demo mock)
- get_dealer_info:       Embedded mock dealer table (DE / UK / IT)
"""

import json
import logging
import os
import urllib.request
import uuid
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION", "us-west-2")
KB_ID_SSM_PARAM = os.environ.get("KB_ID_SSM_PARAM", "/app/tank500/knowledge_base_id")
TAVILY_KEY_SSM_PARAM = os.environ.get(
    "TAVILY_KEY_SSM_PARAM", "/app/tank500/tavily_api_key"
)
LEADS_BUCKET = os.environ.get("LEADS_BUCKET", "")
LEADS_PREFIX = os.environ.get("LEADS_PREFIX", "leads/")
TAVILY_ENDPOINT = "https://api.tavily.com/search"

# Cache resolved values across warm invocations. Only non-empty values are
# cached, so a failed first lookup (e.g. IAM not yet propagated) does not
# poison the cache.
_kb_id_cache = None
_tavily_key_cache = None
_competitors_cache = None

MARKET_QUALIFIER = {
    "de": "Germany",
    "uk": "United Kingdom",
    "it": "Italy",
}

DEALERS = {
    "de": [
        {"name": "GWM Autohaus München", "city": "München", "address": "Landsberger Str. 234, 80687 München", "phone": "+49 89 1234 5678"},
        {"name": "GWM Zentrum Berlin", "city": "Berlin", "address": "Kurfürstendamm 45, 10719 Berlin", "phone": "+49 30 9876 5432"},
        {"name": "GWM Autohaus Frankfurt", "city": "Frankfurt", "address": "Hanauer Landstr. 112, 60314 Frankfurt", "phone": "+49 69 2468 1357"},
    ],
    "uk": [
        {"name": "GWM London West", "city": "London", "address": "142 Great West Road, Brentford TW8 9GA", "phone": "+44 20 7946 0123"},
        {"name": "GWM Manchester", "city": "Manchester", "address": "78 Chester Road, Manchester M16 9EA", "phone": "+44 161 496 0456"},
    ],
    "it": [
        {"name": "GWM Milano Concessionaria", "city": "Milano", "address": "Viale Certosa 210, 20156 Milano", "phone": "+39 02 1234 5678"},
        {"name": "GWM Roma Nord", "city": "Roma", "address": "Via Salaria 719, 00138 Roma", "phone": "+39 06 8765 4321"},
    ],
}


def _get_ssm_param(name, decrypt=False):
    ssm = boto3.client("ssm", region_name=REGION)
    return ssm.get_parameter(Name=name, WithDecryption=decrypt)["Parameter"]["Value"]


def get_kb_id():
    """Resolve the Knowledge Base ID from SSM (cached on success)."""
    global _kb_id_cache
    if _kb_id_cache:
        return _kb_id_cache
    kb_id = ""
    try:
        kb_id = _get_ssm_param(KB_ID_SSM_PARAM)
    except Exception as e:
        logger.warning("Could not read KB ID from SSM %s: %s", KB_ID_SSM_PARAM, e)
        kb_id = os.environ.get("KNOWLEDGE_BASE_ID", "")
    if kb_id:
        _kb_id_cache = kb_id
    return kb_id


def get_tavily_key():
    """Resolve the Tavily API key from SSM SecureString (cached on success)."""
    global _tavily_key_cache
    if _tavily_key_cache:
        return _tavily_key_cache
    key = ""
    try:
        key = _get_ssm_param(TAVILY_KEY_SSM_PARAM, decrypt=True)
    except Exception as e:
        logger.warning("Could not read Tavily key from SSM %s: %s", TAVILY_KEY_SSM_PARAM, e)
    if key:
        _tavily_key_cache = key
    return key


def load_competitors():
    """Load the bundled competitor catalog (cached)."""
    global _competitors_cache
    if _competitors_cache is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "competitors.json")
        with open(path, encoding="utf-8") as f:
            _competitors_cache = json.load(f)
    return _competitors_cache


def lambda_handler(event, context):
    """Main handler - routes to the appropriate tool based on Gateway context."""
    logger.info("EVENT: %s", json.dumps(event, default=str))

    tool_name = ""
    if context and hasattr(context, "client_context") and context.client_context:
        cc = context.client_context
        custom = getattr(cc, "custom", None) or {}
        if isinstance(custom, str):
            import ast

            try:
                custom = ast.literal_eval(custom)
            except Exception:
                custom = json.loads(custom) if custom else {}
        tool_name = custom.get(
            "bedrockAgentCoreToolName", custom.get("bedrockagentcoreToolName", "")
        )

    if not tool_name:
        body = event if isinstance(event, dict) else json.loads(event.get("body", "{}"))
        tool_name = body.get("name", body.get("tool_name", ""))

    # Strip gateway prefix ("tank500-tools___web_search" -> "web_search")
    if "___" in tool_name:
        tool_name = tool_name.split("___", 1)[1]

    logger.info("Resolved tool_name: %s", tool_name)
    arguments = event

    handlers = {
        "retrieve_tank500_info": handle_retrieve_tank500_info,
        "compare_competitor": handle_compare_competitor,
        "web_search": handle_web_search,
        "book_test_drive": handle_book_test_drive,
        "get_dealer_info": handle_get_dealer_info,
    }

    handler = handlers.get(tool_name)
    if not handler:
        return {
            "statusCode": 400,
            "body": json.dumps(
                {"error": f"Unknown tool: {tool_name}. Available: {list(handlers.keys())}"}
            ),
        }

    try:
        result = handler(arguments)
        return {"statusCode": 200, "body": json.dumps(result, ensure_ascii=False)}
    except Exception as e:
        logger.exception("Tool %s failed", tool_name)
        return {"statusCode": 500, "body": json.dumps({"error": str(e)})}


# -----------------------------------------------------------------------------
# Tool: retrieve_tank500_info — Bedrock KB retrieval (owner's manual)
# -----------------------------------------------------------------------------
def handle_retrieve_tank500_info(args):
    query = args.get("query", "")
    kb_id = get_kb_id()
    if not kb_id:
        return {
            "answer": "Knowledge base is not configured yet (run 01-create-kb.sh).",
            "sources": [],
        }

    client = boto3.client("bedrock-agent-runtime", region_name=REGION)
    response = client.retrieve(
        knowledgeBaseId=kb_id,
        retrievalQuery={"text": query},
        retrievalConfiguration={"vectorSearchConfiguration": {"numberOfResults": 5}},
    )

    results = []
    for item in response.get("retrievalResults", []):
        results.append(
            {
                "content": item.get("content", {}).get("text", ""),
                "source": item.get("location", {})
                .get("s3Location", {})
                .get("uri", "unknown"),
                "score": item.get("score", 0),
            }
        )

    if not results:
        return {
            "answer": "No relevant content found in the Tank 500 owner's manual for this query.",
            "sources": [],
        }

    return {
        "answer": "\n\n".join([r["content"] for r in results]),
        "sources": [r["source"] for r in results],
    }


# -----------------------------------------------------------------------------
# Tool: compare_competitor — preset catalog first, Tavily fallback
# -----------------------------------------------------------------------------
def _normalize_competitor(name, catalog):
    """Resolve a user-supplied competitor name to a catalog key, or None."""
    q = " ".join(name.lower().replace("-", " ").split())
    if q in catalog["competitors"]:
        return q
    aliases = catalog.get("aliases", {})
    if q in aliases:
        return aliases[q]
    # Substring match against aliases (longest alias first, so "defender 110"
    # wins over "defender")
    for alias in sorted(aliases, key=len, reverse=True):
        if alias in q:
            return aliases[alias]
    return None


def _filter_aspects(profile, aspects):
    """Optionally narrow a profile to the requested aspects."""
    if not aspects:
        return profile
    keep_map = {
        "dimensions": ["name", "body"],
        "powertrain": ["name", "powertrain", "efficiency"],
        "offroad": ["name", "offroad"],
        "price": ["name", "price_range_indicative", "availability_note"],
        "selling_points": ["name", "selling_points", "vs_tank500"],
    }
    keys = {"name"}
    for a in aspects:
        keys.update(keep_map.get(str(a).lower(), []))
    return {k: v for k, v in profile.items() if k in keys}


def handle_compare_competitor(args):
    competitor_name = args.get("competitor_name", "")
    aspects = args.get("aspects") or []
    catalog = load_competitors()

    key = _normalize_competitor(competitor_name, catalog)
    if key:
        competitor = catalog["competitors"][key]
        return {
            "source": "preset_catalog",
            "data_cutoff": catalog["_meta"]["data_cutoff"],
            "note": catalog["_meta"]["note"],
            # 工具结果级提示：目录数据有截止日期，涉及价格/优惠/新款时
            # Agent 应追加 web_search 拉实时行情（比纯 prompt 约束更可靠）
            "freshness_hint": (
                f"Catalog data is indicative as of {catalog['_meta']['data_cutoff']}. "
                "If the user asks about CURRENT prices, discounts, promotions, availability "
                "or the newest model year, ALSO call web_search to get live market data, "
                "and clearly distinguish catalog specs from live search results."
            ),
            "competitor_specs": _filter_aspects(competitor, aspects),
            "tank500_specs": _filter_aspects(catalog["tank500"], aspects),
        }

    # Not in the preset catalog — fall back to a live web search
    logger.info("Competitor '%s' not in catalog, falling back to web search", competitor_name)
    search = _tavily_search(
        f"{competitor_name} SUV specifications dimensions engine price Europe",
        market=None,
    )
    return {
        "source": "web_search",
        "note": (
            "This competitor is not in the preset catalog; the data below comes from a "
            "live web search. State this to the customer and verify key figures."
        ),
        "competitor_search_results": search.get("results", search),
        "tank500_specs": catalog["tank500"],
    }


# -----------------------------------------------------------------------------
# Tool: web_search — Tavily Search API
# -----------------------------------------------------------------------------
def _tavily_search(query, market=None, max_results=5):
    key = get_tavily_key()
    if not key:
        return {
            "error": "Web search is currently unavailable (no API key configured). "
            "Answer from the knowledge base or suggest contacting a dealer."
        }

    q = query
    if market and market.lower() in MARKET_QUALIFIER:
        q = f"{query} {MARKET_QUALIFIER[market.lower()]}"

    payload = {
        "api_key": key,
        "query": q,
        "max_results": max_results,
        "search_depth": "basic",
    }
    req = urllib.request.Request(
        TAVILY_ENDPOINT,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        logger.warning("Tavily search failed: %s", e)
        return {
            "error": "Web search is temporarily unavailable. "
            "Answer from the knowledge base or suggest contacting a dealer.",
        }

    results = [
        {
            "title": r.get("title", ""),
            "snippet": (r.get("content") or "")[:500],
            "url": r.get("url", ""),
        }
        for r in data.get("results", [])
    ]
    return {"query": q, "results": results}


def handle_web_search(args):
    return _tavily_search(
        args.get("query", ""),
        market=args.get("market"),
        max_results=5,
    )


# -----------------------------------------------------------------------------
# Tool: book_test_drive — demo mock, writes a lead JSON to S3
# -----------------------------------------------------------------------------
def handle_book_test_drive(args):
    name = args.get("name", "").strip()
    contact = args.get("contact", "").strip()
    country = args.get("country", "").strip().lower()
    preferred_date = args.get("preferred_date", "")

    missing = [f for f, v in (("name", name), ("contact", contact), ("country", country)) if not v]
    if missing:
        return {
            "status": "incomplete",
            "message": f"Missing required fields: {', '.join(missing)}. "
            "Please collect them from the customer before booking.",
        }

    lead_id = f"TD-{datetime.now().strftime('%Y')}-{uuid.uuid4().hex[:6].upper()}"
    lead = {
        "lead_id": lead_id,
        "vehicle": "Tank 500",
        "name": name,
        "contact": contact,
        "country": country,
        "preferred_date": preferred_date,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }

    if LEADS_BUCKET:
        try:
            s3 = boto3.client("s3", region_name=REGION)
            s3.put_object(
                Bucket=LEADS_BUCKET,
                Key=f"{LEADS_PREFIX}{lead_id}.json",
                Body=json.dumps(lead, ensure_ascii=False).encode("utf-8"),
                ContentType="application/json",
            )
        except Exception as e:
            # Demo mock: booking still "succeeds" even if persistence fails
            logger.warning("Could not persist lead to S3: %s", e)
    else:
        logger.warning("LEADS_BUCKET not configured; lead not persisted: %s", lead)

    return {
        "status": "booked",
        "lead_id": lead_id,
        "message": "Test drive request registered. A local dealer will contact the customer "
        "within 2 business days to confirm the appointment.",
    }


# -----------------------------------------------------------------------------
# Tool: get_dealer_info — embedded mock dealer table
# -----------------------------------------------------------------------------
def handle_get_dealer_info(args):
    country = args.get("country", "").strip().lower()
    city = (args.get("city") or "").strip().lower()

    dealers = DEALERS.get(country)
    if dealers is None:
        return {
            "error": f"Unknown country '{country}'. Supported: de (Germany), uk (United Kingdom), it (Italy)."
        }

    if city:
        filtered = [d for d in dealers if city in d["city"].lower()]
        if filtered:
            return {"dealers": filtered}
        return {
            "dealers": dealers,
            "note": f"No dealer found in '{city}'; showing all dealers for the country.",
        }
    return {"dealers": dealers}
