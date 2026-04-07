import logging
import os
import json
import urllib.request
import urllib.parse
import urllib.error

import azure.functions as func

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)


def _env(key: str) -> str | None:
    return os.environ.get(key) or None


def _env_required(key: str) -> str:
    value = _env(key)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {key}")
    return value


# ---------------------------------------------------------------------------
# POST credentials to external API (if configured)
# ---------------------------------------------------------------------------

def post_credentials(tenant_id: str, client_id: str, client_secret: str, customer_slug: str) -> None:
    api_url = _env("EXTERNAL_API_URL")
    if not api_url:
        logging.info("No EXTERNAL_API_URL configured — skipping credential POST.")
        return

    payload = json.dumps({
        "tenantId": tenant_id,
        "clientId": client_id,
        "clientSecret": client_secret,
        "customerSlug": customer_slug,
    }).encode("utf-8")

    req = urllib.request.Request(
        api_url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            logging.info(f"Credentials posted to {api_url} — status {resp.status}")
    except Exception as e:
        logging.error(f"Failed to POST credentials to {api_url}: {e}")


# ---------------------------------------------------------------------------
# Self-destruct: delete this Function App via ARM REST API using MSI
# ---------------------------------------------------------------------------

def self_destruct() -> None:
    try:
        subscription_id  = _env_required("SUBSCRIPTION_ID")
        resource_group   = _env_required("RESOURCE_GROUP_NAME")
        function_app_name = _env_required("FUNCTION_APP_NAME")
        msi_endpoint     = _env_required("IDENTITY_ENDPOINT")
        msi_header       = _env_required("IDENTITY_HEADER")

        # Get ARM token from MSI
        token_url = (
            f"{msi_endpoint}"
            f"?api-version=2019-08-01"
            f"&resource=https://management.azure.com/"
        )
        token_req = urllib.request.Request(
            token_url,
            headers={"X-IDENTITY-HEADER": msi_header},
        )
        with urllib.request.urlopen(token_req, timeout=10) as resp:
            token_data = json.loads(resp.read())
        access_token = token_data["access_token"]

        # DELETE the Function App
        arm_url = (
            f"https://management.azure.com/subscriptions/{subscription_id}"
            f"/resourceGroups/{resource_group}"
            f"/providers/Microsoft.Web/sites/{function_app_name}"
            f"?api-version=2023-01-01"
        )
        delete_req = urllib.request.Request(
            arm_url,
            headers={"Authorization": f"Bearer {access_token}"},
            method="DELETE",
        )
        try:
            with urllib.request.urlopen(delete_req, timeout=10) as resp:
                logging.info(f"Self-destruct initiated — ARM returned {resp.status}")
        except urllib.error.HTTPError as e:
            # 202 Accepted is the normal async response for DELETE
            if e.code == 202:
                logging.info("Self-destruct accepted (202) — deletion in progress.")
            else:
                logging.warning(f"Self-destruct ARM call returned {e.code}")

    except Exception as e:
        logging.warning(f"Self-destruct failed (non-fatal): {e}")


# ---------------------------------------------------------------------------
# HTML pages
# ---------------------------------------------------------------------------

def success_html(tenant_id: str, client_id: str, customer_slug: str, has_external_api: bool) -> str:
    external_note = (
        '<p class="note">✅ Credentials have been securely delivered to your API endpoint.</p>'
        if has_external_api else
        '<p class="note">ℹ️ Credentials are stored in the Function App settings and visible in the Azure deployment outputs.</p>'
    )
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Consent Granted</title>
  <style>
    @import url('https://fonts.googleapis.com/css2?family=DM+Mono:wght@400;500&family=DM+Sans:wght@300;400;600&display=swap');
    *, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{
      font-family: 'DM Sans', sans-serif;
      background: #0a0f1e;
      color: #e2e8f0;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 2rem;
    }}
    .card {{
      background: linear-gradient(135deg, #0f1a2e 0%, #162032 100%);
      border: 1px solid #1e3a5f;
      border-radius: 16px;
      padding: 3rem;
      max-width: 560px;
      width: 100%;
      box-shadow: 0 24px 80px rgba(0,0,0,0.5);
    }}
    .icon {{ font-size: 3rem; margin-bottom: 1.5rem; }}
    h1 {{ font-size: 1.75rem; font-weight: 600; color: #38bdf8; margin-bottom: 0.5rem; }}
    .subtitle {{ color: #94a3b8; font-size: 0.95rem; margin-bottom: 2rem; }}
    .info-row {{
      background: #0a1628;
      border: 1px solid #1e3a5f;
      border-radius: 8px;
      padding: 0.75rem 1rem;
      margin-bottom: 0.75rem;
      font-family: 'DM Mono', monospace;
      font-size: 0.8rem;
    }}
    .info-row span {{ color: #64748b; display: block; font-size: 0.7rem; margin-bottom: 2px; }}
    .note {{
      margin-top: 1.5rem;
      padding: 1rem;
      background: #0d2137;
      border-left: 3px solid #38bdf8;
      border-radius: 4px;
      font-size: 0.875rem;
      color: #94a3b8;
      line-height: 1.6;
    }}
    .self-destruct-notice {{
      margin-top: 1rem;
      font-size: 0.75rem;
      color: #475569;
      font-style: italic;
    }}
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">🔐</div>
    <h1>Admin Consent Granted</h1>
    <p class="subtitle">The <strong>Domains.Read.All</strong> application permission has been successfully authorized.</p>
    <div class="info-row"><span>Tenant ID</span>{tenant_id}</div>
    <div class="info-row"><span>Client ID (App Registration)</span>{client_id}</div>
    <div class="info-row"><span>Customer</span>{customer_slug}</div>
    {external_note}
    <p class="self-destruct-notice">🗑️ This temporary Function App is scheduling its own deletion. It is no longer needed.</p>
  </div>
</body>
</html>"""


def error_html(error_code: str, description: str) -> str:
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Consent Error</title>
  <style>
    body {{ font-family: sans-serif; background: #0a0f1e; color: #e2e8f0;
           display: flex; align-items: center; justify-content: center; min-height: 100vh; }}
    .card {{ background: #1a0f0f; border: 1px solid #5f1e1e; border-radius: 16px;
             padding: 3rem; max-width: 500px; width: 100%; }}
    h1 {{ color: #f87171; }}
    pre {{ margin-top: 1rem; font-size: 0.8rem; color: #94a3b8; white-space: pre-wrap; }}
  </style>
</head>
<body>
  <div class="card">
    <h1>⚠️ Consent Was Not Granted</h1>
    <p>Error: <strong>{error_code}</strong></p>
    <pre>{description}</pre>
    <p style="margin-top:1.5rem;color:#64748b;font-size:0.85rem;">
      Please contact your administrator and try the consent URL again.
    </p>
  </div>
</body>
</html>"""


# ---------------------------------------------------------------------------
# HTTP Trigger
# ---------------------------------------------------------------------------

@app.route(route="ConsentHandler", methods=["GET"])
def consent_handler(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("ConsentHandler triggered.")

    error = req.params.get("error")
    error_description = req.params.get("error_description", "")

    if error:
        logging.warning(f"Admin consent denied. error={error} description={error_description}")
        return func.HttpResponse(
            body=error_html(error, error_description),
            mimetype="text/html",
            status_code=200,
        )

    # Consent granted
    tenant_id     = _env_required("TENANT_ID")
    client_id     = _env_required("CLIENT_ID")
    client_secret = _env_required("CLIENT_SECRET")
    customer_slug = _env_required("CUSTOMER_SLUG")

    logging.info(f"Consent granted for tenant={tenant_id} client_id={client_id}")

    post_credentials(tenant_id, client_id, client_secret, customer_slug)

    has_external_api = bool(_env("EXTERNAL_API_URL"))
    html = success_html(tenant_id, client_id, customer_slug, has_external_api)

    self_destruct()

    return func.HttpResponse(
        body=html,
        mimetype="text/html",
        status_code=200,
    )
