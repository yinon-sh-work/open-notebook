import open_notebook.utils.system_certs as sc


def test_disabled_by_default(monkeypatch):
    monkeypatch.delenv(sc.ENV_VAR, raising=False)
    monkeypatch.setattr(sc, "_injected", False)
    assert sc.use_system_trust_store() is False


def test_enabled_injects_once(monkeypatch):
    calls = []

    class FakeTruststore:
        @staticmethod
        def inject_into_ssl():
            calls.append(1)

    monkeypatch.setenv(sc.ENV_VAR, "true")
    monkeypatch.setattr(sc, "_injected", False)
    monkeypatch.setitem(__import__("sys").modules, "truststore", FakeTruststore)
    assert sc.use_system_trust_store() is True
    assert sc.use_system_trust_store() is True
    assert calls == [1]
