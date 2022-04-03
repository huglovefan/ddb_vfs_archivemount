module vfs_archivemount.mountman;

import core.stdc.stdio;
import core.sys.posix.signal;
import core.sys.posix.strings;
import core.sync.mutex;
import core.thread.osthread;
import core.time;
import std.algorithm.searching;
import std.file;
import std.parallelism : TaskPool;
import std.path;
import std.process;
import vfs_archivemount.gc;

private __gshared
{
	Mount[string] mounts;
	Mutex         mtx;
	bool          inited;

	enum max_active_mounts = 5;
}

class MountManException : Exception
{
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
	{
		super(msg, file, line, next);
	}
}

void mountman_init()
{
	assert(!inited);
	mtx = new Mutex();
	inited = true;
}

void mountman_deinit()
{
	if (!inited) return;

	mtx.lock();
	scope(exit)
		mtx.unlock();

	scope tp = new TaskPool(mounts.length);
	foreach (m; tp.parallel(mounts.byValue, 1))
	{
		try
			m.unmount();
		catch (Exception e)
		{
			string s = e.toString();
			printf("%.*s\n", cast(int)s.length, s.ptr);
		}
	}
	tp.finish(/* blocking */ true);

	mounts = null;
}

/// get or create a mount object for the given archive
/// this will mount the archive if we don't already have a Mount for it
/// callers must use Mount.deref() when done using the mount
Mount get_mount(string path)
{
	assert(inited);

	if (!path.exists)
		throw new MountManException("Archive does not exist");

	mtx.lock();
	scope(exit)
		mtx.unlock();

	if (Mount* m = path in mounts)
	{
		m.touch();
		m.refcount++;
		return *m;
	}
	else
	{
		Mount m = (mounts[path] = new Mount(path));
		m.touch();
		m.refcount++;
		if (mounts.length > max_active_mounts)
			mountman_compact();
		return m;
	}
}

class Mount
{
	/// release a reference to this archive
	/// when the reference count becomes 0, the archive may be unmounted
	void deref()
	{
		mtx.lock();
		scope(exit)
			mtx.unlock();

		refcount--;
		assert(refcount >= 0);
	}

	auto mountpoint() { return cast(string)mountpoint_; }

private:

	char[]   archive;
	char[]   mountpoint_;
	Pid      fsPid;
	MonoTime atime;
	int      refcount;

	void touch()
	{
		atime = MonoTime.currTime;
	}

	this(string archive)
	{
		this.archive = archive.gcdup;
		this.mountpoint_ = gcdup(environment["HOME"]~"/mnt/.vfs_archivemount/"~archive.baseName);

		// is it already mounted?
		if (spawnProcess(["mountpoint", "-q", mountpoint]).wait() == 0)
		{
			// probably left over from a previous run but didn't get to unmount
			//  it for whatever reason
			return;
		}

		mountpoint.mkdirRecurse();

		scope(failure)
		{
			try
				mountpoint.rmdir();
			catch (Exception)
				{}
		}

		this.fsPid = spawnProcess(getMountCommand(this.archive, mountpoint));

		scope checkMountedOrExited =
		{
			// exited?
			auto status = fsPid.tryWait();
			if (status.terminated)
				throw new MountManException(cast(string)gcprintf("Mount command exited with status %d", status.status));

			// mounted?
			if (spawnProcess(["mountpoint", "-q", mountpoint]).wait() == 0)
				return true;

			return false;
		};

		// total 10 seconds
		bool mountOk = poll1sec(checkMountedOrExited) || pollticks(18, 500.msecs, checkMountedOrExited);

		if (!mountOk)
		{
			unmount();
			throw new MountManException("Mount command timed out");
		}
	}

	void unmount()
	{
		auto fumo = execute(["timeout", "1", "fusermount", "-u", "--", mountpoint]);

		bool unmountSentSigterm;
		bool unmountSuccess;

		if (fumo.status == 0)
		{
			unmountSuccess = true;
		}
		else if (
			fumo.output.canFind("fusermount: entry for ") &&
			fumo.output.canFind(" not found in /etc/mtab"))
		{
			unmountSuccess = true;
		}
		else if (
			fumo.output.canFind("fusermount: bad mount point ") &&
			fumo.output.canFind(": No such file or directory"))
		{
			unmountSuccess = true;
		}
		else
		{
			// if some files are still open, we get "Device or resource busy"
			// try to kill it with signals
			if (fsPid)
			{
				try
				{
					fsPid.kill(SIGTERM);
					unmountSentSigterm = true;
				}
				catch (Exception e)
				{
					string s = e.toString();
					printf("%.*s\n", cast(int)s.length, s.ptr);
				}
			}
		}

		// if the fs process is running, wait/kill it
		if (fsPid)
		{
			scope check = () => fsPid.tryWait().terminated;

			scope waiter =
			{
				if (poll1sec(check))
					return true;

				// try sigterm if we didn't send it already, otherwise skip straight to sigkill
				if (!unmountSentSigterm)
				{
					fsPid.kill(SIGTERM);
					if (poll1sec(check))
						return true;
				}

				fsPid.kill(SIGKILL);
				if (poll1sec(check))
					return true;

				return false;
			};

			try
			{
				if (waiter())
					fsPid = null;
			}
			catch (Exception e)
			{
				string s = e.toString();
				printf("%.*s\n", cast(int)s.length, s.ptr);
			}
		}

		// if the fs process is gone, clean up the mount point
		// unmount (if the previous attempt failed) and delete the directory
		if (!fsPid)
		{
			try
			{
				if (!unmountSuccess)
				{
					spawnProcess(["timeout", "1", "fusermount", "-u", "--", mountpoint]).wait();
				}

				mountpoint.rmdir();
			}
			catch (Exception e)
			{
				string s = e.toString();
				printf("%.*s\n", cast(int)s.length, s.ptr);
			}
		}
	}
}

private:

/// unmount the oldest mount that has no references
void mountman_compact()
{
	Mount oldest;

	foreach (m; mounts)
	{
		if ((!oldest || m.atime < oldest.atime) && !m.refcount)
			oldest = m;
	}

	if (!oldest)
		return;

	if (!mounts.remove(cast(string)oldest.archive))
		assert(0); // AA should've had it

	oldest.unmount();
}

/// get the command to mount the given archive + mountpoint
string[] getMountCommand(char[] archive, string mountpoint)
{
	if (archive.length >= 4 &&
		!strcasecmp(&archive[$-4], ".rar"))
	{
		return [
			"rar2fs",
			"-f",
			"-o", "ro",
			"-o", "auto_unmount",
			"-o", "kernel_cache",
			"-o", "attr_timeout=60",
			"-o", "entry_timeout=60",
			cast(string)archive,
			mountpoint,
		];
	}
	else
	{
		return [
			"fuse-archive",
			"-f",
			"-o", "ro",
			"-o", "auto_unmount",
			"-o", "kernel_cache",
			"-o", "attr_timeout=60",
			"-o", "entry_timeout=60",
			cast(string)archive,
			mountpoint,
		];
	}
}

bool poll1sec(scope bool delegate() check)
{
	static immutable Duration[] times = [
		1.msecs, // 1
		4.msecs, // 5
		16.msecs, // 20
		30.msecs, // 50
		50.msecs, // 100
		100.msecs, // 200
		400.msecs, // 500
		600.msecs, // 1000
	];

	foreach (tm; times)
	{
		Thread.sleep(tm);

		if (check())
			return true;
	}

	return false;
}

bool pollticks(size_t cnt, Duration dur, scope bool delegate() check)
{
	while (cnt--)
	{
		Thread.sleep(dur);

		if (check())
			return true;
	}

	return false;
}
