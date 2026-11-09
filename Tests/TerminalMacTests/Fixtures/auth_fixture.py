import json
import sys
import time

config = json.load(sys.stdin)
if config["origin"] == "https://slow.example":
    time.sleep(30)
elif config["origin"] == "https://oversized.example":
    sys.stdout.write("x" * (128 * 1024 + 1))
else:
    json.dump({"version": 1, "ok": True, "origin": config["origin"], "username": "fixture-user",
               "relayVersion": 1, "cookies": []}, sys.stdout)
