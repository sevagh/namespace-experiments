# Linux namespace experiments

Some scripts to evaluate sudoers files inside a Linux namespace.

* sudoers-eval.sh

```
$ cat dummy
Host_Alias HELLO = world[1-3]
root    HELLO=(ALL)     ALL
$
$ sudo ./sudoers-eval.sh -u root -h world1 ./dummy
User root may run the following commands on world1:
    (ALL) ALL
$ sudo ./sudoers-eval.sh -u root -h world2 ./dummy
User root may run the following commands on world2:
    (ALL) ALL
$ sudo ./sudoers-eval.sh -u root -h world3 ./dummy
User root may run the following commands on world3:
    (ALL) ALL
$ sudo ./sudoers-eval.sh -u root -h world4 ./dummy
User root is not allowed to run sudo on world4.
```

I'm having trouble supporting `sudo -l -U <user>` because creating a `--user` namespace causes problems with permissions when trying to execute the `sudo` binary from inside the namespace.

* unshare+

A Python script that adds `--uid-map "0 1000 2"` to Bash's `unshare`.

# Motivation

If your sudoers file has lots of aliases, wildcards, [etc.](https://linux.die.net/man/5/sudoers), the `visudo` command can validate them (or format them with JSON if your copy of `visudo` has the `-x` flag). However, it won't resolve the indirection. Here's what I mean:

```
$ cat test-sudoers-file
Runas_Alias DANGEROUS = root
User_Alias INNOCENT = sevagh
INNOCENT remotehost = (DANGEROUS) /bin/sh
$ visudo -cf ./test-sudoers-file
./test-sudoers-file: parsed OK
```

`visudo` will not tell you that sevagh can run `sh` as root. The only way to find that out is to eyeball the file (easy when the file is small but it doesn't scale), or run `sudo -U sevagh -h remotehost -l` on `remotehost` to get the reality of sudoers. From [man sudo](https://linux.die.net/man/8/sudo):

>-l, --list  If no command is specified, list the allowed (and forbidden)
                 commands for the invoking user (or the user specified by the
                 -U option) on the current host.  A longer list format is
                 used if this option is specified multiple times and the
                 security policy supports a verbose output format.

Along with the options `-U user` and `-h host`, you can hypothetically iterate over all of users and hosts and run `sudo -U user -h host -l` to get a real idea of who can run what where.

# Namespaces

A Linux namespace ([man namespace](http://man7.org/linux/man-pages/man7/namespaces.7.html)) lets you isolate system resources in a container:

>       Namespace   Constant          Isolates
       Cgroup      CLONE_NEWCGROUP   Cgroup root directory
       IPC         CLONE_NEWIPC      System V IPC, POSIX message queues
       Network     CLONE_NEWNET      Network devices, stacks, ports, etc.
       Mount       CLONE_NEWNS       Mount points
       PID         CLONE_NEWPID      Process IDs
       User        CLONE_NEWUSER     User and group IDs
       UTS         CLONE_NEWUTS      Hostname and NIS domain name

This list contains everything we need - `CLONE_NEWNS` can help us take `test-sudoers-file` and mount it over `/etc/sudoers`. `CLONE_NEWUTS` can help us change the hostname of the namespace to test various permutations of `sudo -h host`. `CLONE_NEWUSER` can help us create a bunch of fake user accounts to run `sudo -U user` that are not valid users in the parent.

I'll be using the Bash command [unshare](http://man7.org/linux/man-pages/man1/unshare.1.html) to start constructing a proof-of-concept for a namespace sudoers evaluator. First, we'll launch `unshare` with no options:

```
sevagh $ unshare
sevagh $ ps
  PID TTY          TIME CMD
18252 pts/1    00:00:00 bash
19411 pts/1    00:00:00 bash
19446 pts/1    00:00:00 ps
sevagh $ echo $$
19411
sevagh $ sudo -l
[sudo] password for sevagh:
...
User sevagh may run the following commands on sevagh-t450:
    (ALL) ALL
```

Seems like a working little container, but with no isolation - it's inheriting all of my laptop's stuff.

# Isolating /etc/sudoers

Let's try the `CLONE_NEWNS` option for the mount namespace:

```
sevagh $ unshare --mount
unshare: unshare failed: Operation not permitted
```

Why? Who knows - I suspected SELinux but `setenforce 0` didn't help. Let's add `CLONE_NEWUSER` via the `--user` flag:

```
sevagh $ echo "hello" > dummy
sevagh $ unshare --mount --user
nfsnobody $ id
uid=65534(nfsnobody) gid=65534(nfsnobody) groups=65534(nfsnobody) context=unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
nfsnobody $ echo "wow" > dummy
nfsnobody $ logout
sevagh $ cat dummy
wow
```

Now something's happening - but without actually bind mounting the file, we're still modifying it in the parent. Let's try it again but with some tmpfs and bind mounting:

```
sevagh $ unshare --mount --user
nfsnobody $ mktemp -d --tmpdir=/tmp
/tmp/tmp.d1P7Xa6Txs
nfsnobody $ mount -t tmpfs namespace-mnt /tmp/tmp.d1P7Xa6Txs
mount: only root can use "--types" option
```

I want to be root inside my namespace. Since doing all of the mounting and sudo commands and user creation will require root, but the namespace is isolated from my laptop, it shouldn't be a problem to be root inside the namespace. Let's use `--map-root-user`:

>-r, --map-root-user
Run the program only after the current effective user and group IDs have been mapped to the superuser UID and GID in the newly created user namespace. This makes it possible to conveniently gain capabilities needed to manage various aspects of the newly created namespaces (such as configuring interfaces in the network namespace or mounting filesystems in the mount namespace) **even when run unprivileged**.

I bolded the relevant part - this is what I want. When running `unshare` unprivileged, be privileged inside it.

```
sevagh $ unshare --mount --map-root-user
root $ cat /proc/self/uid_map
         0       1000          1
```

To understand the `uid_map` file, this means 0 in the container will map to 1000 in the parent (with a range of 1 starting from the initial value) - so just a single uid, 1000, will be mapped.

We'll try mounting again:

```
sevagh $ unshare --map-root-user --mount
root $ mount -t tmpfs namespace-mnt $(mktemp -d --tmpdir=/tmp)
root $ df -h
Filesystem               Size  Used Avail Use% Mounted on
/dev/mapper/fedora-root   49G   15G   32G  33% /
tmpfs                    3.8G     0  3.8G   0% /sys/fs/cgroup
devtmpfs                 3.8G     0  3.8G   0% /dev
tmpfs                    3.8G   12M  3.8G   1% /dev/shm
tmpfs                    3.8G  2.0M  3.8G   1% /run
tmpfs                    768M   16K  768M   1% /run/user/42
tmpfs                    768M  6.4M  762M   1% /run/user/1000
tmpfs                    3.8G  168K  3.8G   1% /tmp
/dev/sda1                976M  218M  692M  24% /boot
/dev/mapper/fedora-home  177G   12G  156G   7% /home
namespace-mnt            3.8G     0  3.8G   0% /tmp/tmp.nQFaCJItdj
root $ echo "hello" > /tmp/tmp.nQFaCJItdj/fakefile
```

Let's go outside of the namespace and look for the same mount:

```
sevagh $ df -h
Filesystem               Size  Used Avail Use% Mounted on
devtmpfs                 3.8G     0  3.8G   0% /dev
tmpfs                    3.8G   12M  3.8G   1% /dev/shm
tmpfs                    3.8G  2.0M  3.8G   1% /run
tmpfs                    3.8G     0  3.8G   0% /sys/fs/cgroup
/dev/mapper/fedora-root   49G   15G   32G  33% /
tmpfs                    3.8G  168K  3.8G   1% /tmp
/dev/sda1                976M  218M  692M  24% /boot
/dev/mapper/fedora-home  177G   12G  156G   7% /home
tmpfs                    768M   16K  768M   1% /run/user/42
tmpfs                    768M  6.4M  762M   1% /run/user/1000
sevagh $ ls /tmp/tmp.nQFaCJItdj/
sevagh $ sudo ls /tmp/tmp.nQFaCJItdj/
```

This is great - the namespace mount is protected from the parent. This means that in this namespace, if we use a bind mount over `/etc/sudoers`, the parent's real `/etc/sudoers` file won't be affected. Back to the namespace:

```
root $ echo "fake" > /tmp/tmp.nQFaCJItdj/sudoers-copy
root $ cat /tmp/tmp.nQFaCJItdj/sudoers-copy
fake
root $ ls -latrh /tmp/tmp.nQFaCJItdj/sudoers-copy
-rw-r--r--. 1 root root 5 Aug  2 17:43 /tmp/tmp.nQFaCJItdj/sudoers-copy
root $ mount --bind /tmp/tmp.nQFaCJItdj/sudoers-copy /etc/sudoers
root $ cat /etc/sudoers
fake
```

Now we have the `/etc/sudoers` file isolated - that's building block #1 of a namespace-based sudoers evaluator.

# Executing the sudo binary

We run into trouble when running the `sudo` binary:

```
sevagh $ unshare --map-root-user --mount
root $ sudo
sudo: error in /etc/sudo.conf, line 0 while loading plugin "sudoers_policy"
sudo: /usr/libexec/sudo/sudoers.so must be owned by uid 0
sudo: fatal error, unable to load plugins
```

We can use the above mount trick to copy `/usr/libexec/sudo/sudoers.so` somewhere, fiddle with its bits, mount bind over the real one, and off to the races:

```
sevagh $ unshare --map-root-user --mount
root $ cp /usr/libexec/sudo/sudoers.so /tmp/copy-of-sudoers
root $ mount --bind /tmp/co^C
root $ chown root:root /tmp/copy-of-sudoers
root $ mount --bind -o exec /tmp/copy-of-sudoers /usr/libexec/sudo/sudoers.so
root $ sudo
sudo: PERM_SUDOERS: setresuid(-1, 1, -1): Invalid argument
sudo: no valid sudoers sources found, quitting
sudo: unable to initialize policy plugin
```

## The uid_map saga

What's happening here is that I'm missing uid 1. Grep for `PERM_SUDOERS` in the sudo codebase ([here's a convenient GitHub mirror](https://github.com/millert/sudo)) and you'll see comments like `//Assume that uid 1 exists because why wouldn't it` - well, because we're in a fucking namespace, that's why.

If you recall, `--map-root-user` produced a uid_map with `0 1000 1`, meaning 0 in the container mapped to 1000 in the host. I need 1 in the container to map to something - `0 1000 2` would imply that 1 in the container maps to 1001 on my host. Since I, sevagh, am uid 1000, I don't have permission to give my namespace 1001. I need to be root - which I want to avoid.

Another option seems to be defining multiple mappings e.g. `0 1000 1\n1 1000 1`. Let's try it. Since defining a uid_map is a [one-time operation](https://lwn.net/Articles/532593/) and `--map-root-user` already defines one, we'll go with `--user` to be able to define a new mapping:

```
sevagh $ unshare --user --mount
nfsnobody $ cat /proc/self/uid_map
nfsnobody $ echo $$
31584
```

Let's write to it's uid_map first, for a sanity check:

```
# outside namespace (tmux split-pane - parent implications?)
sevagh:~ $ echo "0 1000 1" > /proc/31867/uid_map

# inside namespace
nfsnobody $ cat /proc/self/uid_map
nfsnobody $ echo $$
31867
nfsnobody $ cat /proc/self/uid_map
         0       1000          1
```

Now let's try the mapping we actually wanted:

```
sevagh $ printf "0 1000 1\n1 1000 1" > /proc/32083/uid_map
-bash: printf: write error: Operation not permitted
sevagh $ su -c 'printf "0 1000 1\n1 1000 1" > /proc/32083/uid_map'
Password:
bash: line 0: printf: write error: Operation not permitted
```

It's probably more due to malformed syntax (i.e. not being able to map the same uid twice). Let's go with the original plan of `0 1000 2`:

```
sevagh $ printf "0 1000 2" > /proc/32083/uid_map
-bash: printf: write error: Operation not permitted
sevagh:~ $ su -c 'printf "0 1000 2" > /proc/32203/uid_map'
Password:
```

It worked:

```
nfsnobody:~ $ cat /proc/self/uid_map
         0       1000          2
nfsnobody:~ $ cp /usr/libexec/sudo/sudoers.so /tmp/copy-of-sudoers
nfsnobody:~ $ chown 0 /tmp/copy-of-sudoers
nfsnobody:~ $ mount --bind -o exec /tmp/copy-of-sudoers /usr/libexec/sudo/sudoe
rs.so
nfsnobody:~ $ sudo
sudo: unable to change to root gid: Invalid argument
sudo: unable to initialize policy plugin
```

We need to involve gid map:

```
sevagh:~ $ su -c 'printf "0 1000 2" > /proc/32203/gid_map'
Password:
```

Back to the namespace:

```
nfsnobody:~ $ sudo
sudo: /etc/sudoers is owned by uid 65534, should be 0
sudo: no valid sudoers sources found, quitting
sudo: unable to initialize policy plugin
```

So close:

```
nfsnobody $ vim fake-sudoers
nfsnobody $ cat fake-sudoers
Runas_Alias DANGEROUS = root
User_Alias INNOCENT = sevagh
INNOCENT remotehost = (DANGEROUS) /bin/sh
nfsnobody $
nfsnobody $
nfsnobody $ mount --bind -o exec ./fake-sudoers /etc/sudoers
nfsnobody $ chown 0:0 /etc/sudoers
nfsnobody $ sudo
sudo: setgroups(): Invalid argument
sudo: setgroups(): Invalid argument
```
