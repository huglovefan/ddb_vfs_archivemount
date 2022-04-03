// gc = great convenience
module vfs_archivemount.gc;

import core.stdc.stdarg;
import core.stdc.stdio;
import core.stdc.string;
import core.memory : GC;

debug             version = debug_or_unittest;
version(unittest) version = debug_or_unittest;

// -----------------------------------------------------------------------------

// gcprintf: printf to gc-allocated string

extern(C)
pragma(printf)
char[] gcprintf(const(char)* fmt, ...) nothrow
{
	char[] s = null;
	va_list args;
	va_list args2 = void;

	va_start(args, fmt);
	va_copy(args2, args);
	int rv = vsnprintf(null, 0, fmt, args);
	if (rv != -1)
	{
		s = (cast(char*)GC.malloc(
			cast(size_t)rv+1,
			GC.BlkAttr.NO_SCAN|GC.BlkAttr.APPENDABLE))[0..cast(size_t)rv+1];
		int rv2 = vsnprintf(s.ptr, s.length, fmt, args2);
		assert(rv2 == rv);
	}
	va_end(args2);
	va_end(args);

	version(debug_or_unittest)
	{
		assert(s.ptr == null || s[cast(size_t)rv] == 0);
	}

	return s.ptr != null ? s.ptr[0..cast(size_t)rv] : null;
}

unittest
{
	char[] s = gcprintf("a%d", 1);
	assert(s[0] == 'a');
	assert(s[1] == '1');
	assert(s.ptr[2] == 0);
	assert(s.length == 2);
	gc_assert_bound(s.ptr, s.length+1);

	gcprintf("");
	gcprintf("a");
	gcprintf("ab");
	gcprintf("abc");

	s = gcprintf("[%s%s%s%s]", "aaaa".ptr, "bbbb".ptr, "cccc".ptr, "dddd".ptr);
	assert(0 == strcmp(s.ptr, "[aaaabbbbccccdddd]"));
	gc_assert_bound(s.ptr, s.length+1);

	// null format string
	version(CRuntime_Glibc)
	{
		assert(gcprintf(null).ptr == null);
	}
}

// -----------------------------------------------------------------------------

// gcprintf_sz: gcprintf with the allocation size known in advance

extern(C)
pragma(printf)
char[] gcprintf_sz(size_t bufsz, const(char)* fmt, ...) nothrow
{
	// "bitwise-or 1": let us assume the size isn't 0
	char[] s = (cast(char*)GC.malloc(
		bufsz|1,
		GC.BlkAttr.NO_SCAN|GC.BlkAttr.APPENDABLE))[0..bufsz|1];

	va_list args;
	va_start(args, fmt);
	int rv = vsnprintf(s.ptr, s.length, fmt, args);
	va_end(args);

	if (rv != -1)
	{
		size_t len = cast(size_t)rv;
		if (len >= s.length)
			len = s.length-1;

		version(debug_or_unittest)
			assert(s[len] == 0);

		return s.ptr[0..len];
	}
	else
	{
		return null;
	}
}

unittest
{
	char[] s = gcprintf_sz(0, "");
	assert(s.ptr[0] == 0);
	assert(s.length == 0);
	gc_assert_bound(s.ptr, s.length+1);
	s = gcprintf_sz(1, "");
	assert(s.ptr[0] == 0);
	assert(s.length == 0);
	gc_assert_bound(s.ptr, s.length+1);
	s = gcprintf_sz(2, "");
	assert(s.ptr[0] == 0);
	assert(s.length == 0);
	gc_assert_bound(s.ptr, s.length+1);
	s = gcprintf_sz(0, "1");
	assert(s.ptr[0] == 0);
	assert(s.length == 0);
	gc_assert_bound(s.ptr, s.length+1);
	s = gcprintf_sz(1, "1");
	assert(s.ptr[0] == 0);
	assert(s.length == 0);
	gc_assert_bound(s.ptr, s.length+1);
	s = gcprintf_sz(2, "1");
	assert(s[0] == '1');
	assert(s.ptr[1] == 0);
	assert(s.length == 1);
	gc_assert_bound(s.ptr, s.length+1);
	s = gcprintf_sz(3, "1");
	assert(s[0] == '1');
	assert(s.ptr[1] == 0);
	assert(s.length == 1);
	gc_assert_bound(s.ptr, s.length+1);

	s = gcprintf_sz(5, "hello world");
	assert(strcmp(s.ptr, "hell") == 0);
	assert(s.length == 4);
	gc_assert_bound(s.ptr, s.length+1);
	s = gcprintf_sz(50, "hello world");
	assert(strcmp(s.ptr, "hello world") == 0);
	assert(s.length == 11);
	gc_assert_bound(s.ptr, s.length+1);
}

// -----------------------------------------------------------------------------

// gcstrdup: strdup to a gc-allocated string

char[] gcstrdup(const(char)* s) pure nothrow
{
	if (s)
	{
		size_t len = strlen(s);
		return s[0..len+1].dup.ptr[0..len];
	}
	else
	{
		return null;
	}
}

unittest
{
	const(char)* op = "test";
	char[] np = gcstrdup("test");
	assert(np.ptr != op);
	assert(strcmp(np.ptr, op) == 0);
	assert(np.length == 4);
	gc_assert_bound(np.ptr, np.length+1);
}

// -----------------------------------------------------------------------------

// gcdup: .dup to gc-allocated null-terminated string

char[] gcdup(const(char)[] s) pure nothrow
{
	char* rv = cast(char*)GC.malloc(s.length+1, GC.BlkAttr.NO_SCAN|GC.BlkAttr.APPENDABLE);
	memcpy(rv, s.ptr, s.length);
	rv[s.length] = 0;
	return rv[0..s.length];
}

// -----------------------------------------------------------------------------

// gc_assert_bound: check the size and validity of a gc-allocated pointer

version(unittest) // unused but tests use it
void gc_assert_bound(const(void)* p, size_t sz) nothrow
{
	assert(p, "gc_assert_bound: pointer is null");

	auto t = GC.query(p);

	assert(t.base, "gc_assert_bound: pointer is not gc-allocated");

	if (sz != 0)
	{
		size_t offset = p-t.base;
		size_t reqsize = offset+sz;

		assert(t.size >= reqsize, "gc_assert_bound: allocated size is too small");
	}
}
