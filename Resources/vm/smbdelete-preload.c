// Loaded into smbd in the guest (LD_PRELOAD). The Mac's SMB client keeps a just-written file open for a moment after
// it was closed; deleting such a file, it renames it to .smbdelete<id> and removes it once its handle is closed. Until
// then the folder is not empty, so deleting the folder fails and Finder skips it ("some items had to be skipped").
// Samba checks that a folder is empty by listing it, so the placeholders are left out of listings, and removing a
// folder that holds nothing but placeholders removes them first. Linux deletes open files, and the client's handle
// stays valid until it closes it (its own delete of the file then finds nothing to do; Samba opens it by name).
//
// Built by scripts/build_vm_image.py with clang and ld.lld for aarch64-linux-musl. There are no Linux headers on macOS,
// so the few declarations needed are spelled out here.

struct dirent {  // musl
    unsigned long d_ino;
    long d_off;
    unsigned short d_reclen;
    unsigned char d_type;
    char d_name[256];
};
typedef struct DIR DIR;

long syscall(long number, ...);
int *__errno_location(void);
int openat(int dirfd, const char *path, int flags, ...);
DIR *fdopendir(int fd);
struct dirent *readdir(DIR *dir);
int closedir(DIR *dir);
int close(int fd);
void *dlsym(void *handle, const char *symbol);

#define RTLD_NEXT ((void *)-1)  // musl

#define SYS_unlinkat 35  // aarch64
#define AT_REMOVEDIR 0x200
#define ENOTEMPTY 39
#define O_RDONLY 0
#define O_DIRECTORY 040000  // aarch64
#define O_CLOEXEC 02000000

static int is_placeholder(const char *name) {
    const char *prefix = ".smbdelete";
    for (; *prefix; prefix++, name++) {
        if (*name != *prefix) return 0;
    }
    return 1;
}

static struct dirent *real_readdir(DIR *dir) {
    static struct dirent *(*next)(DIR *);
    if (!next) next = (struct dirent *(*)(DIR *))dlsym(RTLD_NEXT, "readdir");
    return next(dir);
}

struct dirent *readdir(DIR *dir) {
    struct dirent *entry;
    while ((entry = real_readdir(dir)) && is_placeholder(entry->d_name)) {
    }
    return entry;
}

// Removes the placeholders in a folder; returns 1 if nothing else was in it.
static int remove_placeholders(int dirfd, const char *path) {
    int fd = openat(dirfd, path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return 0;
    DIR *dir = fdopendir(fd);
    if (!dir) {
        close(fd);
        return 0;
    }
    int only_placeholders = 1;
    struct dirent *entry;
    while ((entry = real_readdir(dir))) {
        const char *name = entry->d_name;
        if (name[0] == '.' && (name[1] == 0 || (name[1] == '.' && name[2] == 0))) continue;
        if (!is_placeholder(name) || syscall(SYS_unlinkat, fd, name, 0) != 0) only_placeholders = 0;
    }
    closedir(dir);
    return only_placeholders;
}

int unlinkat(int dirfd, const char *path, int flags) {
    int result = (int)syscall(SYS_unlinkat, dirfd, path, flags);
    if (result != 0 && (flags & AT_REMOVEDIR) && *__errno_location() == ENOTEMPTY && remove_placeholders(dirfd, path)) {
        result = (int)syscall(SYS_unlinkat, dirfd, path, flags);
    }
    return result;
}
