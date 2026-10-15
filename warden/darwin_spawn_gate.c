/* Watchtower exec gate. Build only; this is bundled, never compiled on target.
 * Warden records native process creation identity and arms its pipe guardian
 * before sending G. If Warden dies earlier, EOF exits without launching a GUI.
 * execv preserves direct Warden -> Watchtower parentage and launchd's group.
 */
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3 || argv[2][0] != '/') return 64;
    char *end = NULL;
    errno = 0;
    long fd = strtol(argv[1], &end, 10);
    if (errno || !end || *end || fd < 3 || fd > INT_MAX) return 64;
    char value = 0;
    ssize_t n;
    do { n = read((int)fd, &value, 1); } while (n < 0 && errno == EINTR);
    close((int)fd);
    if (n != 1 || value != 'G') return 75;
    char *child[] = {argv[2], NULL};
    execv(argv[2], child);
    return 126;
}
