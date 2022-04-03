module vfs_archivemount.plugin;

import core.stdc.stdio : _IOLBF, SEEK_SET;
import core.stdc.stdlib;
import core.stdc.string;
import core.sys.posix.strings;
import c_deadbeef;
import core.memory : GC;
import core.runtime;
import std.file;
import std.path;
import std.stdio : File;
import vfs_archivemount.gc;
import vfs_archivemount.mountman;
import vfs_archivemount.threadinit;

__gshared DB_functions_t* deadbeef;

struct vfs_archivemount_file
{
	DB_FILE file;
	File    f;
	Mount   mount;
}

// -----------------------------------------------------------------------------

__gshared DB_vfs_t plugindef = {
	plugin: {
		api_vmajor: 1,
		api_vminor: /* DDB_API_LEVEL */ 15,
		type: DB_PLUGIN_VFS,
		id: "vfs_archivemount",
		name: "archivemount vfs",
		descr: "archive read support using archivemount",
		copyright: "",
		website: "",
		start: &vfs_archivemount_start,
		stop: &vfs_archivemount_stop,
	},

	get_schemes:  &vfs_archivemount_get_schemes,
	is_streaming: &vfs_archivemount_is_streaming,
	is_container: &vfs_archivemount_is_container,

	open:      &vfs_archivemount_open,
	close:     &vfs_archivemount_close,
	read:      &vfs_archivemount_read,
	seek:      &vfs_archivemount_seek,
	tell:      &vfs_archivemount_tell,
	rewind:    &vfs_archivemount_rewind,
	getlength: &vfs_archivemount_getlength,

	scandir: &vfs_archivemount_scandir,

	get_scheme_for_name: &vfs_archivemount_get_scheme_for_name,
};

__gshared const(char)*[] scheme_names = [
	"archive://",
	"rar://",
	"zip://",
	"7z://",
	"libarchive://",
	null,
];

// -----------------------------------------------------------------------------

/// dll entry point
extern(C)
DB_plugin_t* vfs_archivemount_load(DB_functions_t* api)
{
	deadbeef = api;
	return &plugindef.plugin;
}

// -----------------------------------------------------------------------------

/// load dll
extern(C)
int vfs_archivemount_start()
{
	if (!rt_init()) return 1;
	setvbuf(stdout, null, _IOLBF, 256);
	mountman_init();
	atexit(&vfs_archivemount_atexit);
	return 0;
}

/// unload dll
extern(C)
int vfs_archivemount_stop()
{
	initForeignThread();
	mountman_deinit();
	return 0;
}

/**
 * atexit handler to deinitialize D runtime
 * 
 * because of the thread-exit handlers added by initForeignThread(), this is
 *  only safe to do at program termination after any foreign threads with the
 *  exit handler should've been joined
 * 
 * notably the artwork plugin is known to call into vfs code from its helper
 *  thread and is usually deinitialized after our plugin
 */
extern(C)
void vfs_archivemount_atexit()
{
	rt_term();
}

// -----------------------------------------------------------------------------

extern(C)
const(char)** vfs_archivemount_get_schemes()
{
	return &scheme_names[0];
}

extern(C)
int vfs_archivemount_is_streaming()
{
	return 0;
}

extern(C)
int vfs_archivemount_is_container(const(char)* fname)
{
	const char *dot = strrchr(fname, '.');
	if (!dot)
		return 0;

	if (!strcasecmp(dot+1, "7z") ||
		!strcasecmp(dot+1, "rar") ||
		!strcasecmp(dot+1, "zip"))
		return 1;

	return 0;
}

extern(C)
const(char)* vfs_archivemount_get_scheme_for_name(const(char)* fname)
{
	const char *ext = strrchr(fname, '.');
	if (!ext)
		return null;

	if (!strcasecmp(ext+1, "7z") ||
		!strcasecmp(ext+1, "rar") ||
		!strcasecmp(ext+1, "zip"))
		return "archive://";

	return null;
}

// -----------------------------------------------------------------------------

alias extern(C) int function(dirent*) scandir_selector_t;
alias extern(C) int function(dirent**, dirent**) scandir_cmp_t;

/**
 * get the list of files inside an archive
 */
extern(C)
int vfs_archivemount_scandir(
	const(char)*        filename,
	dirent***           namelist,
	scandir_selector_t  selector,
	scandir_cmp_t       cmp)
{
	initForeignThread();

	Mount m;
	try
		m = get_mount(cast(string)filename.gcstrdup);
	catch (MountManException e)
	{
		printf("vfs_archivemount_scandir: %.*s\n", cast(int)e.msg.length, e.msg.ptr);
		return -1;
	}
	catch (Exception e)
	{
		string s = e.toString();
		printf("%.*s\n", cast(int)s.length, s.ptr);
		return -1;
	}

	scope(exit)
		m.deref();

	// uh, is this meant to be recursive? or just return one level of names?
	// this seems to work anyway
	string[] names;
	try
	{
		foreach (ent; dirEntries(m.mountpoint, SpanMode.breadth, /* followSymlink */ false))
		{
			if (ent.isFile() && ent.name.starts_with(m.mountpoint~'/'))
				names ~= ent.name[m.mountpoint.length+1..$];
		}
	}
	catch (Exception e)
	{
		printf("vfs_archivemount_scandir: %.*s\n", cast(int)e.msg.length, e.msg.ptr);
		if (!names.length)
			return -1;
	}

	*namelist = cast(dirent**)malloc(names.length * (void*).sizeof);
	foreach (i, name; names)
	{
		dirent de;
		snprintf(&de.d_name[0], de.d_name.sizeof, "%.*s", cast(int)name.length, name.ptr);
		if (name.length >= de.d_name.sizeof)
			printf("vfs_archivemount_scandir: *** name truncated\n");

		(*namelist)[i] = cast(dirent*)malloc(dirent.sizeof);
		*(*namelist)[i] = de;
	}

	return cast(int)names.length;
}

bool starts_with(const(char)[] self, const(char)[] other) pure
{
	return self.length >= other.length && self[0..other.length] == other;
}

// -----------------------------------------------------------------------------

/**
 * open a specific file inside the archive
 * 
 * pathspec is something like "archive:///home/you/archive.rar:dir/file.mp3"
 */
extern(C)
DB_FILE* vfs_archivemount_open(const(char)* pathspec)
{
	initForeignThread();

	char* colon = strchr(cast(char*)pathspec, ':');
	char* arcpath;
	if (colon &&
		colon[1] == '/' &&
		colon[2] == '/')
		arcpath = gcstrdup(colon+3).ptr;
	else
	{
		printf("vfs_archivemount_open: path has no scheme!\n");
		return null;
	}
	colon = strchr(arcpath, ':');
	if (!colon)
	{
		printf("vfs_archivemount_open: path has no colon separating archive member!\n");
		return null;
	}
	*colon = '\0';
	char* filepath = colon+1;

	vfs_archivemount_file* f = new vfs_archivemount_file;
	f.file.vfs = &plugindef;

	try
		f.mount = get_mount(cast(string)arcpath[0..strlen(arcpath)]);
	catch (MountManException e)
	{
		printf("vfs_archivemount_open: Failed to open '%s': %.*s\n", arcpath, cast(int)e.msg.length, e.msg.ptr);
		return null;
	}
	catch (Exception e)
	{
		string s = e.toString();
		printf("%.*s\n", cast(int)s.length, s.ptr);
		return null;
	}

	try
		f.f = File(f.mount.mountpoint~'/'~filepath[0..strlen(filepath)], "r");
	catch (Exception e)
	{
		f.mount.deref();
		printf("vfs_archivemount_open: %.*s\n", cast(int)e.msg.length, e.msg.ptr);
		return null;
	}

	GC.addRoot(f);
	return &f.file;
}

extern(C)
void vfs_archivemount_close(DB_FILE* f_)
{
	initForeignThread();

	vfs_archivemount_file* f = cast(vfs_archivemount_file*)f_;
	GC.removeRoot(f);

	try
		f.f.close();
	catch (Exception e)
		printf("vfs_archivemount_close: %.*s\n", cast(int)e.msg.length, e.msg.ptr);

	f.mount.deref();
}

// -----------------------------------------------------------------------------

extern(C)
size_t vfs_archivemount_read(void* ptr, size_t size, size_t nmemb, DB_FILE* f_)
{
	initForeignThread();
	vfs_archivemount_file* f = cast(vfs_archivemount_file*)f_;

	try
	{
		void[] buf = f.f.rawRead(ptr[0..size*nmemb]);
		assert(buf.length % size == 0); // hasn't been hit so far, worth handling?
		return buf.length / size;
	}
	catch (Exception e)
	{
		printf("vfs_archivemount_read: %.*s\n", cast(int)e.msg.length, e.msg.ptr);
		return -1;
	}
}

extern(C)
int vfs_archivemount_seek(DB_FILE* f_, long offset, int whence)
{
	initForeignThread();
	vfs_archivemount_file* f = cast(vfs_archivemount_file*)f_;

	try
	{
		f.f.seek(offset, whence);
		return 0;
	}
	catch (Exception e)
	{
		printf("vfs_archivemount_seek: %.*s\n", cast(int)e.msg.length, e.msg.ptr);
		return -1;
	}
}

extern(C)
long vfs_archivemount_tell(DB_FILE* f_)
{
	initForeignThread();
	vfs_archivemount_file* f = cast(vfs_archivemount_file*)f_;

	try
		return cast(long)f.f.tell();
	catch (Exception e)
	{
		printf("vfs_archivemount_tell: %.*s\n", cast(int)e.msg.length, e.msg.ptr);
		return -1;
	}
}

extern(C)
void vfs_archivemount_rewind(DB_FILE* f_)
{
	initForeignThread();
	vfs_archivemount_file* f = cast(vfs_archivemount_file*)f_;

	try
		f.f.seek(0, SEEK_SET);
	catch (Exception e)
		printf("vfs_archivemount_rewind: %.*s\n", cast(int)e.msg.length, e.msg.ptr);
}

extern(C)
long vfs_archivemount_getlength(DB_FILE* f_)
{
	initForeignThread();
	vfs_archivemount_file* f = cast(vfs_archivemount_file*)f_;

	try
		return f.f.size();
	catch (Exception e)
	{
		printf("vfs_archivemount_getlength: %.*s\n", cast(int)e.msg.length, e.msg.ptr);
		return -1;
	}
}
