import importlib.util
import io
import json
from contextlib import nullcontext
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

HELPER = Path(__file__).resolve().parents[2] / "Sources/TerminalMac/Auth/auth_session.py"
spec = importlib.util.spec_from_file_location("terminal_mac_auth", HELPER)
auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth)
BASE = "https://example.net"
COOKIE = {"name": "sso", "value": "fixture", "domain": "example.net", "path": "/",
          "expires": -1, "secure": True, "httpOnly": True, "sameSite": "Lax"}


class Response:
    def __init__(self, status=200, payload=None, mime="application/json", location=None, url=None):
        self.status = status
        self.url = url or BASE + auth.IDENTITY_PATH
        self.headers = {"content-type": mime}
        if location is not None:
            self.headers["location"] = location
        self.payload = payload if payload is not None else {"username": "alice", "relayVersion": 1}
        self.disposed = False

    def body(self):
        return json.dumps(self.payload).encode()

    def dispose(self):
        self.disposed = True


class AuthHelperTests(unittest.TestCase):
    def assert_code(self, code, function, *args):
        with self.assertRaises(auth.AuthFailure) as raised:
            function(*args)
        self.assertEqual(raised.exception.code, code)

    def config(self, interactive=False, **changes):
        return {"version": 1, "origin": BASE, "interactive": interactive, "forceLogin": False,
                "mode": "authenticate", **changes}

    def test_origins_and_inputs_are_bounded(self):
        self.assertEqual(auth.origin("https://EXAMPLE.net:443/"), BASE)
        for url in ["http://example.net", "https://u:p@example.net", BASE + "/path", BASE + "?", BASE + "#", BASE + ":0"]:
            self.assert_code("invalid_server", auth.origin, url)
        self.assertEqual(auth.read_config(io.BytesIO(json.dumps(self.config()).encode())), self.config())
        self.assert_code("helper_protocol", auth.read_config, io.BytesIO(b"x" * 8193))
        self.assert_code("helper_protocol", auth.read_config, io.BytesIO(json.dumps(self.config(extra=1)).encode()))
        self.assert_code("login_required", auth.read_config, io.BytesIO(json.dumps(self.config(forceLogin=True)).encode()))

    def test_cookie_scope_path_host_only_expiry_and_secure(self):
        records = [COOKIE, {**COOKIE, "name": "api", "domain": ".example.net", "path": "/api"},
                   {**COOKIE, "name": "expired", "expires": 1},
                   {**COOKIE, "name": "passport", "domain": "passport.example.net"}]
        self.assertEqual([c["name"] for c in auth.applicable_cookies(records, BASE + "/ws/observer/device")], ["sso"])
        self.assertEqual([c["name"] for c in auth.applicable_cookies(records, BASE + "/api/observer/identity")], ["sso", "api"])
        self.assertEqual(auth.applicable_cookies([COOKIE], "https://sub.example.net/"), [])
        self.assertEqual(auth.applicable_cookies([COOKIE], "http://example.net/"), [])
        self.assertEqual(auth.applicable_cookies([records[1]], BASE + "/apix"), [])
        self.assert_code("helper_protocol", auth.clean_cookies, [{**COOKIE, "value": "fixture\r\nHeader: bad"}])
        self.assert_code("helper_protocol", auth.clean_cookies, [{**COOKIE, "expires": True}])
        self.assert_code("helper_protocol", auth.clean_cookies, [COOKIE] * 129)
        result = auth.success(BASE, "alice", records)
        self.assertNotIn("passport", [c["name"] for c in result["cookies"]])

    def test_identity_must_be_formal_same_origin_v1_json(self):
        self.assertEqual(auth.identity_response(Response(), BASE), ("alice", None))
        self.assert_code("server_protocol", auth.identity_response, Response(payload={"probe": "old"}), BASE)
        self.assert_code("server_protocol", auth.identity_response, Response(payload={"username": "alice", "relayVersion": True}), BASE)
        self.assert_code("server_protocol", auth.identity_response, Response(404), BASE)
        self.assert_code("server_protocol", auth.identity_response, Response(403), BASE)
        self.assert_code("server_unavailable", auth.identity_response, Response(503), BASE)
        self.assertEqual(auth.identity_response(Response(mime="text/html"), BASE), (None, "unauthorized"))
        self.assertEqual(auth.identity_response(Response(url="https://other.net/api/observer/identity"), BASE), (None, "unauthorized"))

    def test_controlled_silent_renewal_and_no_bearer(self):
        responses = [Response(302, location="https://passport.example.net/login"),
                     Response(302, location=BASE + auth.IDENTITY_PATH), Response()]
        context = Mock()
        context.request.get.side_effect = responses
        self.assertEqual(auth.validate_cached(context, BASE), "alice")
        for call in context.request.get.call_args_list:
            self.assertEqual(call.kwargs["max_redirects"], 0)
            self.assertEqual(call.kwargs["headers"], {"Accept": "application/json"})
        self.assertTrue(all(response.disposed for response in responses))
        self.assert_code("server_protocol", auth.redirect_url, BASE, "http://example.net/login")
        self.assert_code("server_protocol", auth.redirect_url, BASE, "https://u:p@other.net/login")

    def test_login_page_200_never_proves_authentication(self):
        context = Mock()
        context.request.get.side_effect = [Response(302, location="https://passport.example.net/login"),
            Response(mime="text/html", url="https://passport.example.net/login"), Response(401)]
        self.assertIsNone(auth.validate_cached(context, BASE))

    def test_keychain_cache_is_origin_specific_and_has_no_file_index(self):
        keychain = Mock()
        auth.save_cache(keychain, BASE, [COOKIE])
        service, account, raw = keychain.set_password.call_args.args
        self.assertEqual(service, auth.SERVICE)
        self.assertNotEqual(account, auth.account("https://other.net"))
        keychain.get_password.return_value = raw
        self.assertEqual(auth.load_cache(keychain, BASE), [COOKIE])
        self.assert_code("helper_protocol", auth.load_cache, keychain, "https://other.net")
        payload = json.loads(raw); payload["savedAt"] = 1
        keychain.get_password.return_value = json.dumps(payload)
        self.assertIsNone(auth.load_cache(keychain, BASE))
        keychain.set_password.side_effect = Exception("secret exception must not escape")
        self.assert_code("keychain_failed", auth.save_cache, keychain, BASE, [COOKIE])

    def test_cached_login_is_headless_and_browser_is_closed(self):
        keychain, browser, context = Mock(), Mock(), Mock()
        context.cookies.return_value = [COOKIE]
        with patch.object(auth, "load_cache", return_value=[COOKIE]), patch.object(auth, "launch", return_value=(browser, context)) as launch, \
                patch.object(auth, "validate_cached", return_value="alice"):
            result = auth.authenticate(self.config(), lambda: nullcontext(Mock()), keychain)
        self.assertEqual(result["username"], "alice")
        self.assertEqual(launch.call_args.args[1], True)
        browser.close.assert_called_once()
        keychain.set_password.assert_called_once()

    def test_network_and_5xx_never_clear_cache_or_open_login(self):
        for code in ["network_error", "server_unavailable"]:
            keychain, browser, context = Mock(), Mock(), Mock()
            with patch.object(auth, "load_cache", return_value=[COOKIE]), patch.object(auth, "launch", return_value=(browser, context)) as launch, \
                    patch.object(auth, "validate_cached", side_effect=auth.AuthFailure(code, True)):
                self.assert_code(code, auth.authenticate, self.config(interactive=True), lambda: nullcontext(Mock()), keychain)
            self.assertEqual(launch.call_count, 1)
            self.assertTrue(launch.call_args.args[1])
            browser.close.assert_called_once()
            keychain.set_password.assert_not_called()
            keychain.delete_password.assert_not_called()

    def test_noninteractive_and_check_only_never_open_login(self):
        for config in [self.config(), self.config(interactive=True, mode="check")]:
            with patch.object(auth, "load_cache", return_value=None), patch.object(auth, "launch") as launch:
                self.assert_code("login_required", auth.authenticate, config, lambda: nullcontext(Mock()), Mock())
                launch.assert_not_called()

    def test_expired_cache_opens_exactly_one_interactive_login(self):
        keychain = Mock()
        old_browser, old_context, browser, context, page = [Mock() for _ in range(5)]
        browser.is_connected.return_value = True
        page.is_closed.return_value = False
        context.new_page.return_value = page
        context.request.get.return_value = Response()
        context.cookies.return_value = [COOKIE]
        with patch.object(auth, "load_cache", return_value=[COOKIE]), \
                patch.object(auth, "validate_cached", return_value=None), \
                patch.object(auth, "launch", side_effect=[(old_browser, old_context), (browser, context)]) as launch:
            result = auth.authenticate(self.config(interactive=True), lambda: nullcontext(Mock()), keychain)
        self.assertEqual(result["username"], "alice")
        self.assertEqual([call.args[1] for call in launch.call_args_list], [True, False])
        old_browser.close.assert_called_once()
        browser.close.assert_called_once()
        page.goto.assert_called_once_with(BASE + auth.IDENTITY_PATH, wait_until="domcontentloaded", timeout=30000)
        keychain.set_password.assert_called_once()


if __name__ == "__main__":
    unittest.main()
