#!/usr/bin/env python3
import hashlib
import hmac
import http.server
import json
import os
import subprocess
import sys
import logging
import time

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s',
    stream=sys.stdout,
)
logger = logging.getLogger('subscription-control-api')

PGHOST = os.environ.get('PGHOST', 'localhost')
PGPORT = os.environ.get('PGPORT', '5432')
PGUSER = os.environ['PGUSER']
PGPASSWORD = os.environ['PGPASSWORD']
PGDATABASE = os.environ.get('PGDATABASE', 'subscription')
RETENTION_DAYS = int(os.environ.get('RETENTION_DAYS', '730'))
API_PORT = int(os.environ.get('API_PORT', '8080'))
API_TOKEN = os.environ['API_TOKEN']


def _psql(sql):
    env = os.environ.copy()
    env['PGPASSWORD'] = PGPASSWORD
    cmd = [
        'psql', '-h', PGHOST, '-p', PGPORT,
        '-U', PGUSER, '-d', PGDATABASE,
        '-t', '-A', '-c', sql,
    ]
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


def _sql_escape(value):
    if value is None:
        return ''
    s = str(value)
    s = s.replace("'", "''")
    s = s.replace('\\', '\\\\')
    return s


def check_db():
    return _psql('SELECT 1;').returncode == 0


def init_table():
    sql = """\
CREATE TABLE IF NOT EXISTS subscription (
    id BIGSERIAL PRIMARY KEY,
    acm VARCHAR,
    cluster VARCHAR,
    clusterid VARCHAR,
    type VARCHAR,
    node VARCHAR,
    cpu INTEGER,
    providerid VARCHAR,
    date TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);"""
    result = _psql(sql)
    if result.returncode != 0:
        logger.error('Failed to create table: %s', result.stderr)
        return False
    logger.info('Table subscription ensured')
    return True


def insert_records(records):
    if not records:
        return 0, 'No records to insert'

    chunk_size = 500
    total = 0

    for i in range(0, len(records), chunk_size):
        chunk = records[i:i + chunk_size]
        values = []
        for r in chunk:
            values.append("('{}','{}','{}','{}','{}',{},'{}')".format(
                _sql_escape(r.get('acm', '')),
                _sql_escape(r.get('cluster', '')),
                _sql_escape(r.get('clusterid', '')),
                _sql_escape(r.get('type', '')),
                _sql_escape(r.get('node', '')),
                int(r.get('cpu', 0)),
                _sql_escape(r.get('providerid', '')),
            ))
        sql = (
            'INSERT INTO subscription '
            '(acm,cluster,clusterid,type,node,cpu,providerid) VALUES '
            + ','.join(values) + ';'
        )
        result = _psql(sql)
        if result.returncode != 0:
            return total, 'Insert failed at chunk {}: {}'.format(
                i // chunk_size, result.stderr.strip())
        total += len(chunk)

    return total, None


def purge_records(days):
    sql = "WITH deleted AS (DELETE FROM subscription WHERE date < NOW() - INTERVAL '{} days' RETURNING id) SELECT COUNT(*) FROM deleted;".format(days)
    result = _psql(sql)
    if result.returncode != 0:
        return -1, result.stderr.strip()
    count = result.stdout.strip()
    return int(count) if count else 0, None


def _verify_token(provided):
    return hmac.compare_digest(provided, API_TOKEN)


class APIHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        logger.info('%s %s', self.client_address[0], fmt % args)

    def _json_response(self, status, data):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get('Content-Length', 0))
        return json.loads(self.rfile.read(length))

    def _check_auth(self):
        auth = self.headers.get('Authorization', '')
        if not auth.startswith('Bearer '):
            self._json_response(401, {'error': 'Missing or invalid Authorization header'})
            return False
        token = auth[7:]
        if not _verify_token(token):
            self._json_response(403, {'error': 'Invalid token'})
            return False
        return True

    def do_GET(self):
        if self.path == '/healthz':
            self._json_response(200, {'status': 'ok'})
        elif self.path == '/readyz':
            if check_db():
                self._json_response(200, {'status': 'ready', 'database': 'connected'})
            else:
                self._json_response(503, {'status': 'not ready', 'database': 'disconnected'})
        else:
            self._json_response(404, {'error': 'not found'})

    def do_POST(self):
        if not self._check_auth():
            return

        try:
            data = self._read_body()
        except (json.JSONDecodeError, ValueError) as exc:
            self._json_response(400, {'error': 'Invalid JSON: {}'.format(exc)})
            return

        if self.path == '/api/subscriptions':
            records = data if isinstance(data, list) else data.get('records', [])
            if not records:
                self._json_response(400, {'error': 'No records provided'})
                return

            count, err = insert_records(records)
            if err:
                self._json_response(500, {'error': err, 'inserted': count})
                return

            purged, purge_err = purge_records(RETENTION_DAYS)
            if purge_err:
                logger.warning('Purge failed: %s', purge_err)

            response = {'inserted': count, 'retention_days': RETENTION_DAYS}
            if purged > 0:
                response['purged'] = purged
                logger.info('Purged %d record(s) older than %d days', purged, RETENTION_DAYS)

            self._json_response(201, response)

        else:
            self._json_response(404, {'error': 'not found'})


class ThreadedHTTPServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True


def main():
    logger.info('Connecting to PostgreSQL at %s:%s/%s', PGHOST, PGPORT, PGDATABASE)

    for attempt in range(1, 31):
        if check_db():
            logger.info('Database connection OK')
            break
        logger.warning('DB not ready, retrying in 2s (attempt %d/30)', attempt)
        time.sleep(2)
    else:
        logger.error('Could not connect to database after 30 attempts')
        sys.exit(1)

    if not init_table():
        sys.exit(1)

    server = ThreadedHTTPServer(('0.0.0.0', API_PORT), APIHandler)
    logger.info('Listening on port %d', API_PORT)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info('Shutting down')
        server.shutdown()


if __name__ == '__main__':
    main()
