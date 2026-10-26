#!/usr/bin/env python3
from functools import partial
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control','no-store, max-age=0')
        super().end_headers()
root = Path(__file__).resolve().parent / 'site'
server = ThreadingHTTPServer(('127.0.0.1',8765),partial(Handler,directory=str(root)))
print(f'Curve QA fixture: http://127.0.0.1:8765/ (serving {root})',flush=True)
try: server.serve_forever()
except KeyboardInterrupt: pass
finally: server.server_close()
