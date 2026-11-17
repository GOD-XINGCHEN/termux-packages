/*
 * AlixeHub DEXKit — 内存脱壳脚本
 *
 * 宿主兼容：frida-server(root) / frida-inject(root) / frida-gadget(免root 重打包)
 *
 * 原理：
 *   扫描进程可读内存中的 DEX 魔数 dex\n03x\0，对候选地址按 DEX header 做三重校验：
 *     - header_size(off 0x24) 必须 == 0x70
 *     - file_size(off 0x20) 必须在 [minSize, maxSize] 且 4 字节对齐
 *     - adler32(内存[12, file_size)) 必须等于 header checksum(off 0x08)
 *   三重校验可滤掉绝大多数误报（只匹配魔数的工具会 dump 出一堆垃圾）。
 *   通过校验的数据按 checksum 去重后落盘。
 *
 * 输出目录优先级：
 *   $ALICE_DUMP_DIR  >  app 私有 files/dump  >  /data/local/tmp/alice_dump
 */

'use strict';

var CONFIG = {
    tag: '[alice-dexkit]',
    intervalMs: 2500,          // 轮询间隔：抽取壳需等类被加载
    rounds: 14,                // 轮询轮数（约 35s）
    minSize: 0x70,
    maxSize: 96 * 1024 * 1024,
    scanChunk: 8 * 1024 * 1024,
    maxRangeSize: 512 * 1024 * 1024,
    stopAfterIdleRounds: 3,    // 连续 N 轮无新增即收工
};

function log(m) { console.log(CONFIG.tag + ' ' + m); }

/* ------------------------------------------------------------ 输出目录 */

function outDir() {
    try {
        var env = Java.use('java.lang.System').getenv('ALICE_DUMP_DIR');
        if (env !== null) {
            var s = env.toString();
            if (s.length > 0) return s;
        }
    } catch (e) { }

    try {
        var app = Java.use('android.app.ActivityThread').currentApplication();
        if (app !== null) {
            var ctx = app.getApplicationContext();
            return ctx.getFilesDir().getAbsolutePath() + '/dump';
        }
    } catch (e) { }

    return '/data/local/tmp/alice_dump';
}

/* -------------------------------------------------------------- 校验 */

function adler32(u8) {
    var a = 1, b = 0, MOD = 65521, n = u8.length;
    for (var i = 0; i < n; i++) {
        a += u8[i]; if (a >= MOD) a -= MOD;
        b += a; if (b >= MOD) b -= MOD;
    }
    return ((b << 16) | a) >>> 0;
}

function tryParseDex(addr) {
    var magic;
    try { magic = addr.readCString(8); } catch (e) { return null; }
    if (magic.indexOf('dex\n0') !== 0) return null;

    var ver = magic.substring(4);
    if (['035', '036', '037', '038', '039', '040'].indexOf(ver) < 0) return null;

    var checksum, fileSize, headerSize;
    try {
        checksum = addr.add(0x08).readU32();
        fileSize = addr.add(0x20).readU32();
        headerSize = addr.add(0x24).readU32();
    } catch (e) { return null; }

    if (headerSize !== 0x70) return null;
    if (fileSize < CONFIG.minSize || fileSize > CONFIG.maxSize) return null;
    if ((fileSize & 3) !== 0) return null;

    var body;
    try { body = addr.add(12).readByteArray(fileSize - 12); } catch (e) { return null; }
    if (body === null) return null;
    if (adler32(new Uint8Array(body)) !== checksum) return null;

    return { size: fileSize, checksum: checksum, ver: ver };
}

/* -------------------------------------------------------------- 落盘 */

var seen = {}, seq = 0;

function dumpOne(addr, info, dir) {
    var key = info.checksum.toString(16) + '_' + info.size;
    if (seen[key]) return false;
    seen[key] = 1;

    seq++;
    var name = dir + '/class_' + seq + '_' + info.size.toString(16) + '.dex';
    try {
        var bytes = addr.readByteArray(info.size);
        if (bytes === null) { seq--; return false; }
        var f = new File(name, 'wb');
        f.write(bytes);
        f.flush();
        f.close();
        log('dump ' + name + ' (' + (info.size / 1024).toFixed(1) + 'KB, dex' + info.ver + ')');
        return true;
    } catch (e) {
        seq--;
        log('write fail: ' + e);
        return false;
    }
}

/* -------------------------------------------------------------- 扫描 */

function scanChunk(base, size, dir) {
    var found = 0;
    var cur = base, remain = size;
    while (remain > 0x40) {
        var ms;
        try {
            ms = Memory.scanSync(cur, Math.min(remain, CONFIG.scanChunk), '64 65 78 0a 30 33');
        } catch (e) { break; }
        if (!ms || ms.length === 0) break;

        var lastAddr = null;
        for (var i = 0; i < ms.length; i++) {
            var a = ms[i].address;
            lastAddr = a;
            var info = tryParseDex(a);
            if (info !== null && dumpOne(a, info, dir)) found++;
        }
        if (lastAddr === null) break;
        var next = lastAddr.add(4);
        var adv = next.sub(cur).toInt32();
        if (adv <= 0) break;
        remain -= adv;
        cur = next;
    }
    return found;
}

function scanRound(dir) {
    var ranges;
    try { ranges = Process.enumerateRanges('r--'); } catch (e) { return 0; }

    var found = 0;
    for (var i = 0; i < ranges.length; i++) {
        var r = ranges[i];
        if (r.size < CONFIG.minSize || r.size > CONFIG.maxRangeSize) continue;
        found += scanChunk(r.base, r.size, dir);
    }
    return found;
}

/* -------------------------------------------------------------- 主体 */

function main() {
    var dir = outDir();
    log('frida ' + Frida.version + '  arch=' + Process.arch + '  dir=' + dir);
    try {
        var d = new File(dir, '');
        log('out dir exists=' + d.exists);
    } catch (e) { log('out dir check: ' + e); }

    var idle = 0;
    for (var round = 1; round <= CONFIG.rounds; round++) {
        var n = scanRound(dir);
        log('round ' + round + '/' + CONFIG.rounds + '  new=' + n + '  total=' + seq);
        idle = (n === 0) ? idle + 1 : 0;
        if (idle >= CONFIG.stopAfterIdleRounds) { log('idle, stop early'); break; }
        if (round < CONFIG.rounds) {
            try { Thread.sleep(CONFIG.intervalMs / 1000); } catch (e) { }
        }
    }
    log('DONE  total=' + seq + '  dir=' + dir);
    try { send({ t: 'alice-dexkit-done', dir: dir, count: seq }); } catch (e) { }
}

setImmediate(main);
