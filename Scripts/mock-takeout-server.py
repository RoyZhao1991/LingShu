#!/usr/bin/env python3
# Mock 外卖 + 支付平台(本地,纯模拟,不碰真钱):给灵枢一个可端到端调通的真服务,验证它"真能做事"。
# 端点:
#   GET  /menu?health=<标准>        → 返回符合健康标准的菜单(json)
#   POST /order {dish_id,address,note} → 下单,返回 {order_id, dish, price, status:"待支付"}
#   POST /pay   {order_id, method}     → 支付(模拟),返回 {paid:true, ...}
#   GET  /order/<id>/status            → 配送状态(随支付后时间推进:备餐中→配送中→已送达)
# 所有请求记到 /tmp/mock-takeout.log(可给用户看灵枢真打了哪些 API)。
import json, time, threading, http.server, urllib.parse, sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8930
LOG = "/tmp/mock-takeout.log"
orders = {}
lock = threading.Lock()
_next = [1000]

MENU = [
    {"dish_id": 1, "name": "藜麦鸡胸沙拉",   "kcal": 420, "price": 38, "tags": ["低卡", "高蛋白", "少油少盐"]},
    {"dish_id": 2, "name": "清蒸鲈鱼糙米套餐", "kcal": 480, "price": 45, "tags": ["优质蛋白", "少盐", "粗粮"]},
    {"dish_id": 3, "name": "番茄牛腩杂粮饭",   "kcal": 560, "price": 42, "tags": ["补铁", "高蛋白"]},
    {"dish_id": 4, "name": "白灼时蔬豆腐煲",   "kcal": 360, "price": 32, "tags": ["低卡", "植物蛋白", "清淡"]},
    {"dish_id": 5, "name": "香煎三文鱼藜麦",   "kcal": 510, "price": 58, "tags": ["Omega3", "高蛋白", "少油"]},
]

def log(line):
    with open(LOG, "a") as f:
        f.write(f"[{time.strftime('%H:%M:%S')}] {line}\n")

def status_of(o):
    if not o.get("paid"):
        return "待支付"
    el = time.time() - o["paid_at"]
    if el < 8:   return "备餐中"
    if el < 18:  return "骑手配送中"
    return "已送达"

class H(http.server.BaseHTTPRequestHandler):
    def _send(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length", 0))
        if not n: return {}
        try: return json.loads(self.rfile.read(n) or b"{}")
        except Exception: return {}

    def do_GET(self):
        p = urllib.parse.urlparse(self.path)
        if p.path == "/menu":
            q = urllib.parse.parse_qs(p.query)
            log(f"GET /menu {q.get('health',[''])[0]}")
            self._send({"menu": MENU})
        elif p.path.startswith("/order/") and p.path.endswith("/status"):
            oid = p.path.split("/")[2]
            with lock:
                o = orders.get(oid)
            if not o: return self._send({"error": "order not found"}, 404)
            st = status_of(o)
            log(f"GET status {oid} -> {st}")
            self._send({"order_id": oid, "dish": o["dish"]["name"], "status": st})
        else:
            self._send({"error": "not found"}, 404)

    def do_POST(self):
        p = urllib.parse.urlparse(self.path)
        b = self._body()
        if p.path == "/order":
            did = b.get("dish_id")
            dish = next((d for d in MENU if d["dish_id"] == did), None)
            if not dish: return self._send({"error": "invalid dish_id"}, 400)
            with lock:
                oid = str(_next[0]); _next[0] += 1
                orders[oid] = {"dish": dish, "address": b.get("address", ""), "paid": False, "created": time.time()}
            log(f"POST /order dish={dish['name']} addr={b.get('address','')} -> #{oid}")
            self._send({"order_id": oid, "dish": dish["name"], "price": dish["price"], "status": "待支付"})
        elif p.path == "/pay":
            oid = str(b.get("order_id", ""))
            with lock:
                o = orders.get(oid)
                if not o: return self._send({"error": "order not found"}, 404)
                o["paid"] = True; o["paid_at"] = time.time(); o["method"] = b.get("method", "")
            log(f"POST /pay #{oid} method={b.get('method','')} -> PAID ¥{o['dish']['price']}")
            self._send({"paid": True, "order_id": oid, "amount": o["dish"]["price"], "method": b.get("method", ""), "status": "备餐中"})
        else:
            self._send({"error": "not found"}, 404)

    def log_message(self, *a): pass   # 静默(自己记日志)

if __name__ == "__main__":
    open(LOG, "w").write(f"=== mock 外卖平台启动 :{PORT} @ {time.strftime('%H:%M:%S')} ===\n")
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
