"""Read a consistent, read-only view of the iPhone Photos catalogue over AFC."""

import asyncio
import functools
import struct

import apsw
from pymobiledevice3.exceptions import AfcFileNotFoundError

DB = "/PhotoData/Photos.sqlite"
WAL = DB + "-wal"
LIMIT = 96 * 1024 * 1024


def checksum(data, endian, first=0, second=0):
    for a, b in struct.iter_unpack(endian + 'II', data):
        first = (first + a + second) & 0xffffffff
        second = (second + b + first) & 0xffffffff
    return first, second


def committed_frames(data, page_size):
    if len(data) < 32:
        return {}, None
    magic, version, wal_page_size = struct.unpack_from('>III', data)
    if magic not in (0x377f0682, 0x377f0683) or wal_page_size != page_size:
        raise RuntimeError('Unexpected SQLite WAL header')
    endian = '>' if magic & 1 else '<'
    sums = checksum(data[:24], endian)
    if sums != struct.unpack_from('>II', data, 24):
        raise RuntimeError('WAL header checksum mismatch')
    salts = data[16:24]
    frames, committed, page_count = {}, {}, None
    for offset in range(32, len(data) - page_size - 23, page_size + 24):
        frame = data[offset:offset+24]
        if frame[8:16] != salts:
            break
        page, size = struct.unpack_from('>II', frame)
        contents = data[offset+24:offset+24+page_size]
        sums = checksum(frame[:8] + contents, endian, *sums)
        if sums != struct.unpack_from('>II', frame, 16):
            break
        frames[page] = contents
        if size:
            committed.update(frames)
            frames.clear()
            page_count = size
    return committed, page_count


async def read_catalog(afc, earliest_capture, recent_additions, check_unlocked):
    async def revision():
        await check_unlocked()
        items = []
        for path in (DB, WAL):
            try:
                info = await afc.stat(path)
                items.append((info['st_size'], info['st_mtime']))
            except AfcFileNotFoundError:
                items.append((0, None))
        return tuple(items)

    baseline = await revision()
    wal_size = baseline[1][0]
    if wal_size > LIMIT // 2:
        raise RuntimeError('iPhone 照片目录正在大量更新，请稍后重试')
    wal = bytearray()
    if wal_size:
        wal_handle = await afc.fopen(WAL, 'r')
        try:
            while len(wal) < wal_size:
                await check_unlocked()
                chunk = await afc.fread(wal_handle, min(1024 * 1024, wal_size - len(wal)))
                if not chunk:
                    raise RuntimeError("iPhone 相册在读取时发生变化，请重试")
                wal.extend(chunk)
        finally:
            await afc.fclose(wal_handle)
    await check_unlocked()
    handle = await afc.fopen(DB, 'r')
    bytes_read = len(wal)

    async def read_at(offset, count):
        nonlocal bytes_read
        if bytes_read + count > LIMIT:
            raise RuntimeError('本次读取的 iPhone 目录超过上限，请缩小同步日期范围')
        await check_unlocked()
        await afc.fseek(handle, offset)
        data = await afc.fread(handle, count)
        if len(data) != count:
            raise RuntimeError('Short catalogue read')
        bytes_read += len(data)
        return data

    try:
        header = await read_at(0, 100)
        if not header.startswith(b'SQLite format 3\x00'):
            raise RuntimeError('Not a SQLite database')
        page_size, = struct.unpack_from('>H', header, 16)
        page_size = 65536 if page_size == 1 else page_size
        pages, wal_count = committed_frames(wal, page_size)
        size = wal_count * page_size if wal_count is not None else baseline[0][0]
        loop = asyncio.get_running_loop()

        @functools.lru_cache(maxsize=4096)
        def page_at(number):
            if number in pages:
                return pages[number]
            return asyncio.run_coroutine_threadsafe(read_at((number-1)*page_size,page_size), loop).result(timeout=7)

        class RemoteFile:
            def xRead(self, length, offset):
                end = offset + length
                if end > size:
                    raise apsw.IOError('read past EOF')
                first, last = offset//page_size+1, (end-1)//page_size+1
                data = bytearray(b''.join(page_at(n) for n in range(first,last+1)))
                if first == 1:
                    data[18:20] = b'\x01\x01'
                start = offset % page_size
                return bytes(data[start:start+length])

            def xFileSize(self): return size
            def xClose(self): pass
            def xLock(self, level): pass
            def xUnlock(self, level): pass
            def xCheckReservedLock(self): return False
            def xFileControl(self, op, ptr): return False
            def xSectorSize(self): return page_size
            def xDeviceCharacteristics(self): return apsw.SQLITE_IOCAP_IMMUTABLE

        class RemoteVFS(apsw.VFS):
            def xOpen(self, name, flags):
                if not flags[0] & apsw.SQLITE_OPEN_MAIN_DB:
                    raise apsw.CantOpenError('Only the read-only catalogue is served')
                flags[1] = apsw.SQLITE_OPEN_READONLY
                return RemoteFile()

        def query():
            vfs = RemoteVFS("iphone-sync-readonly", "unix")
            try:
                with apsw.Connection("file:iphone-catalog?immutable=1", flags=apsw.SQLITE_OPEN_READONLY | apsw.SQLITE_OPEN_URI, vfs="iphone-sync-readonly") as connection:
                    connection.execute("PRAGMA query_only=ON")
                    columns = {column[1] for column in connection.execute("PRAGMA table_info(ZASSET)")}
                    clauses = ["ZDATECREATED >= ?"]
                    args = [earliest_capture]
                    if recent_additions is not None and "ZADDEDDATE" in columns:
                        clauses.append("ZADDEDDATE >= ?")
                        args.append(recent_additions)
                    sql = f"""SELECT ZUUID, ZDATECREATED, ZKIND, ZKINDSUBTYPE, ZDIRECTORY, ZFILENAME
                              FROM ZASSET WHERE ZTRASHEDSTATE=0 AND ZKIND IN (0,1)
                              AND ZUUID IS NOT NULL AND ZDATECREATED IS NOT NULL
                              AND ({' OR '.join(clauses)})
                              ORDER BY ZDATECREATED, ZUUID"""
                    return list(connection.execute(sql, args))
            finally:
                vfs.unregister()

        rows = await asyncio.to_thread(query)
        if await revision() != baseline:
            raise RuntimeError("iPhone 相册在读取时发生变化，请重试")
        return rows
    finally:
        await afc.fclose(handle)
