#!/usr/bin/env python3
"""Discover paired iPhones and append one verified batch to Apple Photos."""

import argparse
import asyncio
from collections import defaultdict
from contextlib import AsyncExitStack, asynccontextmanager, nullcontext
from datetime import datetime, timedelta, timezone
import fcntl
from functools import partial
import hashlib
from ipaddress import ip_address
import json
import math
import os
from pathlib import Path, PurePosixPath
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

from makelive import is_live_photo_pair
from pymobiledevice3.exceptions import ConnectionTerminatedError
from pymobiledevice3.lockdown import create_using_mobdev2, create_using_usbmux, get_mobdev2_lockdowns
from pymobiledevice3.remote.tunnel_service import CoreDeviceTunnelProxy
from pymobiledevice3.remote.userspace_tunnel import TunnelProvider, UserspaceRsdTunnel
from pymobiledevice3.services.afc import AfcService
from pymobiledevice3.services.notification_proxy import RemoteNotificationProxyService
from pymobiledevice3.usbmux import select_devices_by_connection_type

from phone_catalog import read_catalog

EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
EPOCH_UNIX = EPOCH.timestamp()
VIDEOS = {".mov", ".mp4", ".m4v"}
IMAGES = {".heic", ".heif", ".jpg", ".jpeg", ".png", ".dng", ".tiff", ".tif", ".gif"}
LOCK_STATE = "com.apple.springboard.lockstate"


class SyncDeferred(Exception):
    def __init__(self, message, *, locked=False):
        super().__init__(message)
        self.exit_status = 2 if locked else 3


@asynccontextmanager
async def unlocked_only(phone):
    version = tuple(int(part) for part in phone.product_version.split(".")[:2] if part.isdecimal())
    if version < (27, 2):
        raise SyncDeferred("检查解锁状态需要 iOS 27.2 或更新版本")

    async def provider():
        return TunnelProvider(await CoreDeviceTunnelProxy.create(phone))

    async with AsyncExitStack() as stack:
        try:
            async with asyncio.timeout(10):
                rsd = await stack.enter_async_context(UserspaceRsdTunnel(provider_factory=provider))
                proxy = await stack.enter_async_context(RemoteNotificationProxyService(rsd))
        except Exception as exc:
            raise SyncDeferred(f"无法确认 iPhone 的解锁状态（{type(exc).__name__}）") from exc

        checked_at = -math.inf

        async def check(*, force=False):
            nonlocal checked_at
            if not force and time.monotonic() - checked_at < 1:
                return
            try:
                state = await asyncio.wait_for(proxy.notify_get_state(LOCK_STATE), timeout=3)
            except Exception as exc:
                raise SyncDeferred(f"无法确认 iPhone 的解锁状态（{type(exc).__name__}）") from exc
            if state == 1:
                raise SyncDeferred("iPhone 已锁定", locked=True)
            if state != 0:
                raise SyncDeferred("iPhone 返回了未知的锁定状态")
            checked_at = time.monotonic()

        await check()
        yield check


async def skip_unlock_check(*, force=False):
    pass


def log(message):
    print(message, flush=True)


def progress(args, phase, **values):
    if args.progress:
        log("@progress " + json.dumps({"phase": phase, **values}))


def phone_info(phone):
    values = phone.short_info
    serial = phone.udid
    if serial and (values.get("DeviceClass") == "iPhone" or str(values.get("ProductType", "")).startswith("iPhone")):
        return {"id": serial, "name": values.get("DeviceName") or "iPhone"}
    return None


async def discover():
    found = {}
    network = await select_devices_by_connection_type(connection_type="Network")
    for connection in network:
        try:
            phone = await asyncio.wait_for(create_using_usbmux(serial=connection.serial, connection_type="Network", autopair=False), timeout=6)
            async with phone:
                if phone.paired and (details := phone_info(phone)):
                    found[details["id"]] = details
        except Exception as error:
            print(f"无法读取一个配对设备：{error}", file=sys.stderr)
    try:
        async with asyncio.timeout(8):
            async for address, phone in get_mobdev2_lockdowns(only_paired=True, timeout=5):
                async with phone:
                    if phone.paired and (details := phone_info(phone)):
                        details["address"] = address
                        found[details["id"]] = details
    except Exception as error:
        print(f"Bonjour 设备搜索未完成：{error or type(error).__name__}", file=sys.stderr)
    log(json.dumps(list(found.values()), ensure_ascii=False))


async def connect_phone(serial, direct_ip=None, report=None, remember_address=None):
    async def connect_network_mux():
        network = await select_devices_by_connection_type(connection_type="Network")
        if not any(connection.serial == serial for connection in network):
            raise RuntimeError("无线设备列表中没有所选 iPhone")
        return await create_using_usbmux(serial=serial, connection_type="Network", autopair=False)

    async def connect_direct():
        try:
            host = str(ip_address(direct_ip.strip()))
        except ValueError:
            raise RuntimeError("备用 IP 地址无效") from None
        return await create_using_mobdev2(hostname=host, udid=serial)

    routes = [
        ("macOS usbmuxd 网络连接", 7, connect_network_mux),
        ("Bonjour mobdev2", 10, partial(create_using_mobdev2, udid=serial, timeout=7)),
    ]
    if direct_ip and direct_ip.strip():
        routes.append((f"IP 直连 {direct_ip.strip()}", 5, connect_direct))

    failures = []
    for route, timeout, connect in routes:
        try:
            async with asyncio.timeout(timeout):
                phone = await connect()
                details = phone_info(phone)
                if not phone.paired or not details or details["id"] != serial:
                    await phone.close()
                    raise RuntimeError("配对未验证或设备与所选 iPhone 不一致")
        except Exception as exc:
            reason = str(exc) or type(exc).__name__
            failures.append(f"{route} · {reason}")
            if report:
                report(f"连接未成功 · {failures[-1]}")
            continue
        if report:
            report(f"Wi-Fi 已连接 · {details['name']} · {route}")
        if remember_address and route == "Bonjour mobdev2":
            remember_address(phone.hostname)
        return phone
    raise RuntimeError("无法连接所选 iPhone" if report else "；".join(failures))


def library_assets(library):
    database = library / "database" / "Photos.sqlite"
    if not (library / "originals").is_dir() or not database.is_file():
        raise RuntimeError("找不到目标图库。请检查硬盘是否已挂载，以及路径是否指向 .photoslibrary。")
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=8) as conn:
        return {row[0]: row[1:] for row in conn.execute("""SELECT ZUUID, ZKIND, ZKINDSUBTYPE, ZDIRECTORY, ZFILENAME, ZDATECREATED
                    FROM ZASSET WHERE ZTRASHEDSTATE=0 AND ZKIND IN (0,1)""")}


def file_hash(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def indexed_originals(library, rows):
    index = defaultdict(list)
    originals = (library / "originals").resolve()
    for identifier, (kind, subtype, directory, filename, _) in rows.items():
        if not directory or not filename or Path(filename).name != filename:
            continue
        path = originals / directory / filename
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(originals):
            continue
        index[(kind, path.stat().st_size)].append((identifier, subtype, path))
    return index


def matching_asset(index, item):
    main = item["primary"]
    for identifier, subtype, path in index[(item["kind"], main["size"])]:
        partner = item.get("companion")
        if bool(partner) != (item["kind"] == 0 and subtype == 2):
            continue
        if file_hash(path) != main["hash"]:
            continue
        if not partner:
            return identifier
        motion = path.with_name(path.stem + "_3.mov")
        if motion.is_file() and motion.stat().st_size == partner["size"] and file_hash(motion) == partner["hash"]:
            return identifier
    return None


def open_state(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=8)
    db.executescript("""
        CREATE TABLE IF NOT EXISTS start (scope TEXT PRIMARY KEY, capture REAL NOT NULL, first_seen REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS assets (scope TEXT NOT NULL, phone_id TEXT NOT NULL,
            capture REAL NOT NULL, retry_after REAL NOT NULL DEFAULT 0, photos_id TEXT,
            PRIMARY KEY(scope,phone_id));
    """)
    return db


async def pull(afc, remote, directory, check_unlocked):
    await check_unlocked(force=True)
    path = str(remote)
    info = await afc.stat(path)
    size = info["st_size"]
    if size <= 0:
        raise RuntimeError("iPhone 原片暂不可读取")
    if size + 64 * 1024 * 1024 > shutil.disk_usage(directory).free:
        raise RuntimeError("Mac 暂存空间不足")
    destination = directory / remote.name
    digest = hashlib.sha256()
    handle = await afc.fopen(path, "r")
    try:
        with destination.open("xb") as stream:
            pending = size
            while pending:
                await check_unlocked()
                data = await afc.fread(handle, min(1024 * 1024, pending))
                if not data or len(data) > pending:
                    raise RuntimeError("无线传输未完整完成")
                pending -= len(data)
                digest.update(data)
                stream.write(data)
    finally:
        await afc.fclose(handle)
    after = await afc.stat(path)
    if (size, info["st_mtime"]) != (after["st_size"], after["st_mtime"]):
        raise RuntimeError("原片在传输期间发生变化")
    return {"path": destination, "size": size, "hash": digest.hexdigest()}


async def stage_asset(afc, row, directory, check_unlocked):
    identifier, capture, kind, subtype, source_dir, name = row
    if not isinstance(name, str) or not isinstance(source_dir, str) or PurePosixPath(name).name != name:
        raise RuntimeError("图库没有提供本地原片路径")
    remote = PurePosixPath("/") / source_dir.strip("/") / name
    if len(remote.parts) < 4 or remote.parts[1] != "DCIM" or ".." in remote.parts:
        raise RuntimeError("原片暂未出现在 iPhone 的 DCIM")
    if remote.suffix.lower() not in (VIDEOS if kind == 1 else IMAGES):
        raise RuntimeError(f"暂不支持 {remote.suffix} 文件")
    directory.mkdir()
    item = {"id": identifier, "capture": capture, "kind": kind,
            "primary": await pull(afc, remote, directory, check_unlocked)}
    if kind == 0 and subtype == 2:
        await check_unlocked()
        candidates = [PurePosixPath(name) for name in await afc.listdir(str(remote.parent))]
        partners = [candidate for candidate in candidates if candidate.name == str(candidate)
                    and candidate.stem.casefold() == remote.stem.casefold() and candidate.suffix.lower() == ".mov"]
        if len(partners) != 1:
            raise RuntimeError("未找到实况照片的配对视频")
        pair = await pull(afc, remote.parent / partners[0], directory, check_unlocked)
        if not is_live_photo_pair(item["primary"]["path"], pair["path"]):
            raise RuntimeError("实况照片的配对标识不匹配")
        item["companion"] = pair
    return item


def commit_item(db, scope, phone_id, photos_id):
    with db:
        db.execute("UPDATE assets SET photos_id=?,retry_after=0 WHERE scope=? AND phone_id=?", (photos_id, scope, phone_id))


def database_identity(path):
    stat = path.stat()
    with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2) as conn:
        row = conn.execute("SELECT Z_UUID FROM Z_METADATA LIMIT 1").fetchone()
    if not row or not row[0]:
        raise RuntimeError("无法读取目标图库的标识")
    return stat.st_dev, stat.st_ino, row[0]


def check_library_conflicts(database, identity):
    listing = subprocess.run(
        ["/usr/sbin/lsof", "-nP", "-a", "-u", str(os.getuid()), "-c", "photolibraryd", "-Fn"],
        capture_output=True, text=True, timeout=8,
    )
    if listing.returncode not in (0, 1):
        raise RuntimeError("无法检查照片后台服务打开的图库")
    opened = {Path(line[1:]).resolve() for line in listing.stdout.splitlines()
              if line.startswith("n/") and line.endswith("/database/Photos.sqlite")}
    for other in opened - {database}:
        try:
            other_identity = database_identity(other)
        except (OSError, sqlite3.Error, RuntimeError):
            continue
        if other_identity[2] == identity[2] and other_identity[:2] != identity[:2]:
            raise RuntimeError("照片后台服务仍打开着同一图库的另一份副本，本次未写入。")


def request_photokit(library, identity, groups):
    items = []
    for group in groups:
        item = group[0]
        request = {"kind": item["kind"], "capture": item["capture"],
                   "primary": str(item["primary"]["path"])}
        if "companion" in item:
            request["companion"] = str(item["companion"]["path"])
        items.append(request)
    log("@photokit " + json.dumps({"library": str(library), "device": identity[0],
                                  "inode": identity[1], "items": items}))
    reply = sys.stdin.readline()
    if not reply:
        raise RuntimeError("App 未返回 PhotoKit 导入结果")
    result = json.loads(reply)
    identifiers = result.get("identifiers")
    if isinstance(identifiers, list) and len(identifiers) == len(groups):
        return [identifier.split("/")[0] if isinstance(identifier, str) else "" for identifier in identifiers]
    if result.get("domain") == "PHPhotosErrorDomain" and result.get("code") in (3302, 3303, 3306) and len(groups) > 1:
        middle = len(groups) // 2
        return (request_photokit(library, identity, groups[:middle])
                + request_photokit(library, identity, groups[middle:]))
    log(f"PhotoKit 导入未完成 · {result.get('error') or '未返回预期数量的图库记录'}")
    return [""] * len(groups)


def import_staged(library, items, db, scope):
    database = library / "database" / "Photos.sqlite"
    identity = database_identity(database)
    before = library_assets(library)
    index = indexed_originals(library, before)
    pending = {}
    duplicates = 0
    for item in items:
        if identifier := matching_asset(index, item):
            commit_item(db, scope, item["id"], identifier)
            duplicates += 1
            continue
        key = (item["kind"], item["primary"]["hash"], item.get("companion", {}).get("hash"))
        pending.setdefault(key, []).append(item)
    if not pending:
        return 0, duplicates, 0

    check_library_conflicts(database, identity)
    groups = list(pending.values())
    identifiers = request_photokit(library, identity, groups)
    if database_identity(database) != identity:
        raise RuntimeError("导入时目标图库发生变化，未更新同步进度。")

    # A completed transaction can take a moment to become visible to the read-only database connection.
    expected = {identifier for identifier in identifiers if identifier}
    after = library_assets(library)
    for _ in range(5):
        if expected.issubset(after):
            break
        time.sleep(0.4)
        after = library_assets(library)
    if database_identity(database) != identity:
        raise RuntimeError("核验时目标图库发生变化，未更新同步进度。")

    imported = failures = 0
    for identifier, group in zip(identifiers, groups):
        row = after.get(identifier)
        if row is not None and identifier not in before and matching_asset(indexed_originals(library, {identifier: row}), group[0]):
            for item in group:
                commit_item(db, scope, item["id"], identifier)
            imported += 1
            duplicates += len(group) - 1
        else:
            failures += len(group)
    if failures:
        log("部分项目未能在指定图库中核验，下次会重新判重并继续。")
    return imported, duplicates, failures


def is_shared_album_asset(row):
    directory = row[4]
    return isinstance(directory, str) and PurePosixPath(directory.strip("/")).parts[:2] == (
        "PhotoData", "PhotoCloudSharingData"
    )


async def sync(args):
    library = Path(args.library).expanduser().resolve()
    if library.suffix != ".photoslibrary":
        raise RuntimeError("请选择一个 .photoslibrary 文件")
    initial = library_assets(library)
    dated = [row[-1] for row in initial.values() if isinstance(row[-1], (int, float)) and math.isfinite(row[-1])]
    origin = max(dated) - 2 if dated else -10**9
    scope = hashlib.sha256(f"{args.device}\0{library}".encode()).hexdigest()
    with open_state(Path(args.state)) as db:
        entry = db.execute("SELECT capture,first_seen FROM start WHERE scope=?", (scope,)).fetchone()
        first_seen = entry[1] if entry else time.time() - EPOCH_UNIX - 60
        floor = args.start - EPOCH_UNIX if args.start is not None else (entry[0] if entry else origin)
        log("正在通过 Wi-Fi 连接 iPhone…" if args.allow_locked else "正在通过 Wi-Fi 检查 iPhone 是否解锁…")
        async with (
            await connect_phone(
                args.device, direct_ip=args.direct_ip, report=log,
                remember_address=lambda address: log("@device-address " + address),
            ) as phone,
            (nullcontext(skip_unlock_check) if args.allow_locked else unlocked_only(phone)) as check_unlocked,
            AfcService(phone) as afc,
        ):
            log("正在通过 Wi-Fi 读取 iPhone 相册目录…")
            catalog = await read_catalog(afc, floor, first_seen, check_unlocked)
            rows = [row for row in catalog if not is_shared_album_asset(row)]
            skipped = len(catalog) - len(rows)
            if skipped:
                log(f"已跳过共享相簿 {skipped} 项。")
            now = time.time()
            saved = {phone_id: (photos_id, retry_after) for phone_id, photos_id, retry_after in
                     db.execute("SELECT phone_id, photos_id, retry_after FROM assets WHERE scope=?", (scope,))}
            todo = [row for row in rows if not saved.get(row[0], (None, 0))[0]]
            candidates = [row for row in todo if saved.get(row[0], (None, 0))[1] <= now][:args.batch]
            counts = {"total": len(rows), "remaining": len(todo), "batch": len(candidates)}
            if args.preview:
                log(f"目录中有 {len(todo)} 个待核对项目，本批可核对 {len(candidates)} 项。")
                for _, capture, kind, subtype, _, name in candidates:
                    date = (EPOCH + timedelta(seconds=capture)).astimezone().strftime("%Y-%m-%d %H:%M:%S")
                    label = "视频" if kind == 1 else "实况照片" if subtype == 2 else "照片"
                    log(f"{date}  {label}  {name or '原文件暂不可用'}")
                progress(args, "preview", **counts)
                return
            with db:
                db.execute("INSERT OR IGNORE INTO start VALUES(?,?,?)", (scope, origin, first_seen))
                db.executemany("INSERT OR IGNORE INTO assets(scope,phone_id,capture) VALUES(?,?,?)",
                               ((scope, row[0], row[1]) for row in rows))
            if not candidates:
                log("暂时没有可处理的项目，稍后会重试。" if todo else "当前同步范围已全部核对。")
                progress(args, "idle", **counts)
                return
            progress(args, "transfer", attempted=0, **counts)
            staging_parent = Path(args.state).parent / "Staging"
            staging_parent.mkdir(exist_ok=True)
            with tempfile.TemporaryDirectory(prefix="batch-", dir=staging_parent) as directory:
                working = Path(directory)
                items = []
                failed_reads = 0
                deferred = None
                disconnected = None
                for number,row in enumerate(candidates, 1):
                    try:
                        item = await asyncio.wait_for(
                            stage_asset(afc, row, working / f"{number:03d}", check_unlocked), timeout=120
                        )
                        items.append(item)
                        log(f"已读取 {number}/{len(candidates)} · {item['primary']['path'].name}")
                    except SyncDeferred as exc:
                        deferred = exc
                        break
                    except Exception as exc:
                        if not args.allow_locked:
                            try:
                                await check_unlocked(force=True)
                            except SyncDeferred as interruption:
                                deferred = interruption
                                break
                        if isinstance(exc, ConnectionTerminatedError):
                            disconnected = exc
                            break
                        failed_reads += 1
                        with db:
                            db.execute("UPDATE assets SET retry_after=? WHERE scope=? AND phone_id=?", (time.time()+900, scope, row[0]))
                        log(f"待重试 {number}/{len(candidates)} · {exc}")
                    progress(args, "transfer", attempted=number, **counts)
                if items:
                    progress(args, "import", **counts)
                imported, duplicates, failures = import_staged(library, items, db, scope) if items else (0, 0, 0)
                if failures:
                    with db:
                        db.executemany("UPDATE assets SET retry_after=? WHERE scope=? AND phone_id=? AND photos_id IS NULL",
                                       ((time.time()+900, scope, item["id"]) for item in items))
                done = {row[0] for row in db.execute("SELECT phone_id FROM assets WHERE scope=? AND photos_id IS NOT NULL", (scope,))}
                after = sum(row[0] not in done for row in rows)
                result = "本批已处理" if deferred or disconnected else "本批完成"
                log(f"{result} · 新增 {imported} · 已存在 {duplicates} · 待重试 {failures+failed_reads} · 目录剩余 {after}")
                progress(args, "complete", total=len(rows), remaining=after, batch=len(candidates),
                         imported=imported, duplicates=duplicates, retry=failures+failed_reads)
                if deferred:
                    raise deferred
                if disconnected:
                    raise disconnected


def main():
    parser = argparse.ArgumentParser()
    actions = parser.add_subparsers(dest="action", required=True)
    actions.add_parser("devices")
    run = actions.add_parser("sync")
    run.add_argument("--device", required=True)
    run.add_argument("--direct-ip", help="设备发现失败后使用的局域网 IP 地址")
    run.add_argument("--library", required=True)
    run.add_argument("--state", required=True)
    run.add_argument("--batch", type=int, choices=range(1, 151), default=10)
    run.add_argument("--start", type=float)
    run.add_argument("--preview", action="store_true")
    run.add_argument("--allow-locked", action="store_true", help="按 AFC 可读性判断，允许锁屏时读取")
    run.add_argument("--progress", action="store_true")
    args = parser.parse_args()
    try:
        if args.action == "devices":
            asyncio.run(discover())
        else:
            if not args.device:
                raise RuntimeError("请选择一个经过配对的 iPhone")
            state_path = Path(args.state)
            state_path.parent.mkdir(parents=True, exist_ok=True)
            with state_path.with_suffix(".lock").open("a") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise RuntimeError("已有一批同步或预览正在运行") from None
                asyncio.run(sync(args))
    except SystemExit as exc:
        if isinstance(exc.code, str):
            log(f"本批延后 · {exc.code}")
            raise SystemExit(1) from None
        raise
    except SyncDeferred as exc:
        log(f"本次拉取已停止 · {exc}")
        raise SystemExit(exc.exit_status) from None
    except Exception as exc:
        log(f"本次未完成 · {exc}")
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
