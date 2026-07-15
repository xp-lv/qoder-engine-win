"""跨平台文件锁工具。
Unix 使用 fcntl.flock，Windows 使用 msvcrt.locking。
v-longrun: 增加超时机制，防止长程任务中永久阻塞。
"""
import sys, time

_IS_WINDOWS = sys.platform == 'win32'

if _IS_WINDOWS:
    import msvcrt

    def acquire_lock(file_obj, timeout=60):
        """获取排他锁（Windows）。v-longrun: 增加 timeout 参数。"""
        deadline = time.monotonic() + timeout
        while True:
            try:
                file_obj.seek(0)
                msvcrt.locking(file_obj.fileno(), msvcrt.LK_NBLCK, 1)
                return True
            except OSError:
                if time.monotonic() >= deadline:
                    return False
                time.sleep(1)

    def release_lock(file_obj):
        """释放锁（Windows）。"""
        try:
            file_obj.seek(0)
            msvcrt.locking(file_obj.fileno(), msvcrt.LK_UNLCK, 1)
        except OSError:
            pass
else:
    import fcntl

    def acquire_lock(file_obj, timeout=60):
        """获取排他锁（Unix）。v-longrun: 非阻塞模式+重试循环，防止永久阻塞。"""
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(file_obj, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return True
            except OSError:
                if time.monotonic() >= deadline:
                    return False
                time.sleep(1)

    def release_lock(file_obj):
        """释放锁（Unix）。"""
        try:
            fcntl.flock(file_obj, fcntl.LOCK_UN)
        except OSError:
            pass
