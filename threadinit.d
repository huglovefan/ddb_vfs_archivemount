module vfs_archivemount.threadinit;

import core.thread.osthread : Thread;

pragma(inline, true)
void initForeignThread()
{
	if (!Thread.getThis())
		doInitForeignThread();
}

// -----------------------------------------------------------------------------

private:

// -----------------------------------------------------------------------------

import core.stdc.stdio : printf;
import core.stdc.stdlib : abort;
import core.thread.osthread : rt_moduleTlsCtor, rt_moduleTlsDtor, thread_attachThis;
import core.thread.threadbase : thread_detachThis, thread_setThis;

version(Posix) import core.stdc.stdio : perror;
version(Posix) import core.stdc.errno : errno;
version(Posix) import core.sys.posix.pthread : pthread_key_create, pthread_key_t, pthread_setspecific;
version(Posix) import core.atomic : atomicStore, cas;

version(Windows) import core.sys.windows.winbase : GetLastError;
version(Windows) import core.sys.windows.windef : BOOL, DWORD, PVOID;

debug             version = debug_or_unittest;
version(unittest) version = debug_or_unittest;

version(Posix) version = posix_shared_druntime; // dmd: -L-lphobos2, ldc: --link-defaultlib-shared

// -----------------------------------------------------------------------------

void doInitForeignThread() nothrow
{
	version(debug_or_unittest) assert(!Thread.getThis());

	version(Posix)
	{
		pthread_key_t key = void;
		if (int err = pthread_key_create(&key, &deinitForeignThread))
		{
			errno = err;
			perror("threadinit: pthread_key_create");
			abort();
		}
	}
	version(Windows)
	{
		DWORD idx = FlsAlloc(&deinitForeignThread);
		if (idx == FLS_OUT_OF_INDEXES)
		{
			printf("threadinit: FlsAlloc: %u\n", GetLastError());
			abort();
		}
	}

	try
		thread_attachThis();
	catch (Throwable e)
		pfatal("threadinit: thread_attachThis", e);
	version(debug_or_unittest) assert(Thread.getThis());

	version(posix_shared_druntime)
	{
		while (!cas(&libs_busy, false, true)) continue;
		version(debug_or_unittest) assert(libs);
		inheritLoadedLibraries(libs);
		libs = pinLoadedLibraries();
		version(debug_or_unittest) assert(libs);
		libs_busy.atomicStore(false);
	}

	version(debug_or_unittest) assert(tlsinit == 0);
	try
		rt_moduleTlsCtor();
	catch (Throwable e)
		pfatal("threadinit: rt_moduleTlsCtor", e);
	version(debug_or_unittest) assert(tlsinit == 1);

	version(Posix)
	{
		if (int err = pthread_setspecific(key, cast(void*)1))
		{
			errno = err;
			perror("threadinit: pthread_setspecific");
			abort();
		}
	}
	version(Windows)
	{
		if (!FlsSetValue(idx, cast(void*)1))
		{
			printf("threadinit: FlsSetValue: %u\n", GetLastError());
			abort();
		}
	}
}

extern(C)
void deinitForeignThread(void*) nothrow
{
	string which = void;
	try
	{
		version(debug_or_unittest) which = null;
		version(debug_or_unittest) assert(Thread.getThis());
		version(debug_or_unittest) assert(tlsinit == 1);
		which = "threadinit: rt_moduleTlsDtor";
		rt_moduleTlsDtor();
		version(debug_or_unittest) which = null;
		version(debug_or_unittest) assert(tlsinit == 0);
		which = "threadinit: thread_detachThis";
		thread_detachThis();
		version(debug_or_unittest) which = null;
		version(debug_or_unittest) thread_setThis(null);
		version(debug_or_unittest) assert(!Thread.getThis());
	}
	catch (Throwable e)
		pfatal(which, e);
}

// -----------------------------------------------------------------------------

noreturn pfatal(string fnname, const(Throwable) e) nothrow
{
	printf("%.*s: %.*s(%llu): %.*s\n",
		cast(int)fnname.length, fnname.ptr,
		cast(int)e.file.length, e.file.ptr,
		cast(ulong)e.line,
		cast(int)e.msg.length, e.msg.ptr);
	for (;;) abort();
}

// -----------------------------------------------------------------------------

version(posix_shared_druntime) __gshared
{
	// using mangleFunc at compile time leaves some garbage in the binary so just do these manually
	//import core.demangle : mangleFunc;
	//pragma(msg, mangleFunc!(void* function() nothrow @nogc)("rt.sections_elf_shared.pinLoadedLibraries"));
	//pragma(msg, mangleFunc!(void function(void*) nothrow @nogc)("rt.sections_elf_shared.inheritLoadedLibraries"));

	pragma(mangle, "_D2rt19sections_elf_shared18pinLoadedLibrariesFNbNiZPv")
	void* pinLoadedLibraries() nothrow @nogc;

	pragma(mangle, "_D2rt19sections_elf_shared22inheritLoadedLibrariesFNbNiPvZv")
	void inheritLoadedLibraries(void*) nothrow @nogc;

	void* libs;
	bool libs_busy;
	shared static this()
	{
		version(debug_or_unittest) assert(!libs);
		libs = pinLoadedLibraries();
		version(debug_or_unittest) assert(libs);
	}
}

version(Windows)
{
	// https://docs.microsoft.com/en-us/windows/win32/api/fibersapi/nf-fibersapi-flsalloc
	extern(Windows) DWORD FlsAlloc(PFLS_CALLBACK_FUNCTION) nothrow @nogc;
	enum DWORD FLS_OUT_OF_INDEXES = -1;

	// https://docs.microsoft.com/en-us/windows/win32/api/winnt/nc-winnt-pfls_callback_function
	alias extern(C) void function(PVOID) PFLS_CALLBACK_FUNCTION;

	// https://docs.microsoft.com/en-us/windows/win32/api/fibersapi/nf-fibersapi-flssetvalue
	extern(Windows) BOOL FlsSetValue(DWORD, PVOID) nothrow @nogc;

	// https://docs.microsoft.com/en-us/windows/win32/api/fibersapi/nf-fibersapi-flsfree
	extern(Windows) BOOL FlsFree(DWORD) nothrow @nogc;
}

// -----------------------------------------------------------------------------

version(debug_or_unittest)
{
	ubyte tlsinit;
	static this() { assert(++tlsinit == 1); }
	static ~this() { assert(--tlsinit == 0); }
}

version(unittest)
{
	__gshared int ctors;
	__gshared int dtors;
	static this() { ctors++; }
	static ~this() { dtors++; }
}

unittest
{
	import core.thread.osthread;

	assert(Thread.getThis() !is null);

	ctors = 0;
	dtors = 0;
	auto t = new Thread({
		assert(Thread.getThis() !is null);
		assert(ctors == 1);
		assert(dtors == 0);
	});
	t.start();
	t.join();
	assert(ctors == 1);
	assert(dtors == 1);

	ctors = 0;
	dtors = 0;
	createLowLevelThread({
		assert(Thread.getThis() is null);
		assert(ctors == 0);
		assert(dtors == 0);
	}).joinLowLevelThread;
	assert(ctors == 0);
	assert(dtors == 0);

	createLowLevelThread({
		assert(Thread.getThis() is null);
		assert(ctors == 0);
		assert(dtors == 0);
		try
			initForeignThread();
		catch (Throwable e)
			assert(0, e.msg);
		assert(Thread.getThis() !is null);
		assert(ctors == 1);
		assert(dtors == 0);
	}).joinLowLevelThread;
	assert(ctors == 1);
	assert(dtors == 1);
}
