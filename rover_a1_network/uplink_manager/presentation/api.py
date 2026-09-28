"""HTTP API + static page. Basic auth on everything except /healthz.

POSTs must carry `X-Requested-With: netui`. A cross-site form cannot set that header, so a page
elsewhere can't use the browser's cached basic-auth login to switch the router's uplink.
"""

from __future__ import annotations

import json
import logging
import os
import secrets
import time
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import FileResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from pydantic import BaseModel, Field

from ..application.jobs import Busy, Job, JobRunner
from ..application.ports import RouterError
from ..application.service import UplinkService
from ..domain.invariants import UplinkSettings
from ..domain.wifi import CredentialError

log = logging.getLogger('uplink_manager')
STATIC = Path(__file__).parent / 'static'


class SwitchRequest(BaseModel):
    ssid: str = Field(min_length=1, max_length=32)
    encryption: str
    key: str | None = Field(default=None, max_length=64)
    radio: str | None = Field(default=None, pattern=r'^radio[0-9]$')


class ActionRequest(BaseModel):
    id: str = Field(pattern=r'^(adopt|delete):[A-Za-z0-9_]{1,32}$')


def create_app(service: UplinkService, user: str, password: str) -> FastAPI:
    app = FastAPI(title='Rover uplink manager', docs_url=None, redoc_url=None, openapi_url=None)
    basic = HTTPBasic(realm='rover-network')

    def auth(cred: HTTPBasicCredentials = Depends(basic)) -> None:
        ok_user = secrets.compare_digest(cred.username.encode(), user.encode())
        ok_pw = secrets.compare_digest(cred.password.encode(), password.encode())
        if not (ok_user and ok_pw):
            raise HTTPException(401, 'bad login', headers={'WWW-Authenticate': 'Basic realm="rover-network"'})

    def csrf(x_requested_with: str | None = Header(default=None)) -> None:
        if x_requested_with != 'netui':
            raise HTTPException(403, 'missing X-Requested-With: netui')

    def router_call(fn):
        try:
            return fn()
        except RouterError as e:
            raise HTTPException(502, str(e)) from e

    def started(fn) -> dict:
        try:
            job: Job = fn()
        except Busy as e:
            raise HTTPException(409, str(e)) from e
        except (CredentialError, ValueError) as e:
            raise HTTPException(400, str(e)) from e
        return {'job': job.id}

    @app.get('/healthz')
    def healthz():
        return {'ok': True}

    @app.get('/', dependencies=[Depends(auth)])
    def index():
        return FileResponse(STATIC / 'index.html', headers={'Cache-Control': 'no-store'})

    @app.get('/api/status', dependencies=[Depends(auth)])
    def status():
        return router_call(service.status)

    @app.get('/api/scan', dependencies=[Depends(auth)])
    def scan():
        return router_call(service.scan)

    @app.get('/api/audit', dependencies=[Depends(auth)])
    def audit():
        return router_call(service.audit)

    @app.post('/api/switch', dependencies=[Depends(auth), Depends(csrf)])
    def switch(req: SwitchRequest):
        return started(lambda: service.start_switch(req.ssid, req.encryption, req.key, req.radio))

    @app.post('/api/repair', dependencies=[Depends(auth), Depends(csrf)])
    def repair():
        return started(service.start_repair)

    @app.post('/api/action', dependencies=[Depends(auth), Depends(csrf)])
    def action(req: ActionRequest):
        return started(lambda: service.start_action(req.id))

    @app.get('/api/jobs', dependencies=[Depends(auth)])
    def jobs():
        cur = service.jobs.current
        return {'current': cur.id if cur else None,
                'recent': [{'id': j.id, 'kind': j.kind, 'status': j.status, 'result': j.result,
                            'started': j.started} for j in service.jobs.recent()]}

    @app.get('/api/jobs/{job_id}', dependencies=[Depends(auth)])
    def job(job_id: int):
        j = service.jobs.get(job_id)
        if j is None:
            raise HTTPException(404, 'no such job')
        return j.to_dict()

    return app


def job_logger(path: Path | None):
    """Append every finished job (already redacted) to a JSON-lines file on the data volume."""
    def write(job: Job) -> None:
        log.info('job #%d %s %s: %s', job.id, job.kind, job.status, job.result)
        if path is None:
            return
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open('a') as f:
                f.write(json.dumps({'time': time.strftime('%Y-%m-%dT%H:%M:%S'), **job.to_dict()}) + '\n')
        except OSError as e:
            log.warning('cannot write %s: %s', path, e)
    return write


def settings_from_env() -> UplinkSettings:
    return UplinkSettings(
        uplink_iface=os.environ.get('UPLINK_IFACE') or 'wan1',
        uplink_zone=os.environ.get('UPLINK_ZONE') or 'wwan',
        lan_zone=os.environ.get('LAN_ZONE') or 'lan',
        client_nets=tuple((os.environ.get('CLIENT_NETS') or 'lan WWAN').split()))


def main() -> None:
    import uvicorn

    from ..infrastructure.ssh_router import SshRouter

    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(name)s %(levelname)s %(message)s')
    data = Path(os.environ.get('NETUI_DATA') or '/data')
    router = SshRouter(os.environ.get('RUTX11_HOST') or '192.168.1.1',
                       os.environ.get('RUTX11_USER') or 'root',
                       os.environ['RUTX11_PASSWORD'],
                       known_hosts=data / 'known_hosts')
    service = UplinkService(router, settings_from_env(),
                            JobRunner(audit_log=job_logger(data / 'jobs.log')))
    app = create_app(service, os.environ.get('NETUI_USER') or 'rover', os.environ['NETUI_PASSWORD'])
    uvicorn.run(app, host=os.environ.get('NETUI_BIND') or '0.0.0.0',
                port=int(os.environ.get('NETUI_PORT') or 5080), log_level='info')


if __name__ == '__main__':
    main()
