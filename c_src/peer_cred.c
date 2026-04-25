/*
 * peer_cred.c — A5a.2 peer-credential lookup NIF.
 *
 * Resolves the (uid, gid) of the process on the other end of a connected
 * Unix-domain socket, given the OS file descriptor. Three platforms:
 *
 *   FreeBSD / macOS  →  getpeereid(2)
 *   Linux            →  getsockopt(SO_PEERCRED) → struct ucred
 *
 * The NIF returns {:ok, %{uid, gid}} or {:error, posix_atom}. Errno
 * values are translated to atoms because the Elixir caller treats the
 * boundary as a security gate, not a debug surface — anything other
 * than :ok closes the connection.
 *
 * The body runs in microseconds (a single syscall) so a regular NIF is
 * fine; no dirty scheduler.
 */

#if defined(__linux__) && !defined(_GNU_SOURCE)
  #define _GNU_SOURCE 1
#endif

#include <erl_nif.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

#if defined(__FreeBSD__) || defined(__APPLE__)
  #include <sys/types.h>
#elif defined(__linux__)
  #include <sys/socket.h>
  #include <sys/types.h>
#endif

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_uid;
static ERL_NIF_TERM atom_gid;
static ERL_NIF_TERM atom_unsupported_platform;

static ERL_NIF_TERM make_errno_atom(ErlNifEnv *env, int err) {
    const char *name = strerror(err);
    if (name == NULL) name = "unknown";
    return enif_make_atom(env, name);
}

static ERL_NIF_TERM peer_cred_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    int fd;

    if (argc != 1 || !enif_get_int(env, argv[0], &fd)) {
        return enif_make_badarg(env);
    }

    uid_t uid = 0;
    gid_t gid = 0;
    int rc = -1;

#if defined(__FreeBSD__) || defined(__APPLE__)
    rc = getpeereid(fd, &uid, &gid);
#elif defined(__linux__)
    struct ucred cred;
    socklen_t len = sizeof(cred);
    rc = getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len);
    uid = cred.uid;
    gid = cred.gid;
#else
    return enif_make_tuple2(env, atom_error, atom_unsupported_platform);
#endif

    if (rc != 0) {
        return enif_make_tuple2(env, atom_error, make_errno_atom(env, errno));
    }

    ERL_NIF_TERM map = enif_make_new_map(env);
    enif_make_map_put(env, map, atom_uid, enif_make_uint(env, (unsigned int) uid), &map);
    enif_make_map_put(env, map, atom_gid, enif_make_uint(env, (unsigned int) gid), &map);

    return enif_make_tuple2(env, atom_ok, map);
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    (void) priv;
    (void) info;
    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atom_uid = enif_make_atom(env, "uid");
    atom_gid = enif_make_atom(env, "gid");
    atom_unsupported_platform = enif_make_atom(env, "unsupported_platform");
    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"peer_cred_nif", 1, peer_cred_nif, 0}
};

ERL_NIF_INIT(Elixir.Zed.Ops.PeerCred, nif_funcs, load, NULL, NULL, NULL)
