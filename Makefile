SRCS = \
	plugin.d \
	threadinit.d \
	mountman.d \
	gc.d \
	c_deadbeef.i \

vfs_archivemount.so: $(SRCS)
	dmd -O -g -shared -debug -defaultlib=libphobos2.so $^ -of=$@

watch: $(SRCS)
	ls $(SRCS) | entr -cs 'make -s'

install:
	@mkdir -pv ~/.local/lib/deadbeef && \
	cp -v vfs_archivemount.so ~/.local/lib/deadbeef/vfs_archivemount.so.tmp && \
	mv -v ~/.local/lib/deadbeef/vfs_archivemount.so.tmp ~/.local/lib/deadbeef/vfs_archivemount.so

c_deadbeef.i:
	cpp -DDDB_API_LEVEL=15 -D__asm__\(x\)= -D__restrict= -I$$HOME/git -include deadbeef/deadbeef.h /dev/null >$@
