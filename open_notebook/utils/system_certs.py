"""Use the operating-system certificate store for outbound HTTPS.

Python (httpx / requests) trusts only the bundled ``certifi`` roots by default,
so model servers on a closed network that are signed by an internal CA fail
with ``CERTIFICATE_VERIFY_FAILED`` even when that CA is installed in
Windows' "Trusted Root Certification Authorities".

Set ``OPEN_NOTEBOOK_USE_SYSTEM_CERTS=true`` to make every SSL context use the
OS trust store (Windows certificate store / macOS Keychain / Linux system CAs)
via the ``truststore`` package. Off by default so Docker installs are unchanged.

``ESPERANTO_SSL_CA_BUNDLE`` (a CA file path) still works and takes precedence
for Esperanto clients.
"""

from __future__ import annotations

import os

from loguru import logger

ENV_VAR = "OPEN_NOTEBOOK_USE_SYSTEM_CERTS"
_injected = False


def use_system_trust_store() -> bool:
    """Inject the OS trust store into ``ssl`` if enabled. Idempotent.

    Must run before any HTTP client / SSL context is created.
    Returns True when the OS trust store is active.
    """
    global _injected
    if _injected:
        return True

    if os.getenv(ENV_VAR, "").strip().lower() not in ("1", "true", "yes", "on"):
        return False

    try:
        import truststore

        truststore.inject_into_ssl()
        _injected = True
        logger.info("Using the operating-system certificate store for HTTPS")
    except Exception as e:  # pragma: no cover - depends on platform
        logger.warning(f"Could not enable the OS certificate store: {e}")
    return _injected
