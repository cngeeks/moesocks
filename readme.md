MoeSocks
========


A socks5 proxy using the client / server architecture.

MoeSocks is greatly inspired by [shadowsocks].

A sample `config.json` file is included in this repository and the cabal
archive.

type `moesocks --help` for help.

Features
--------
* TCP port forwarding 
* Per connection throttling (as a side effect of trying to find a bug in the
remote)

Not working
-----------
* Remote is flaky 
* IPv6
* Socks4 / Socks4a
* UDP over Socks5
* Four times slower then original Python's implementation

Planning features
------------------
* None

Note
------

There's a bug that prevents remote from working correctly.

You should use the python implementation of [shadowsocks] on the remote
server.

There is an earlier implementation of [shadowsocks in Haskell] by rnons that
makes MoeSocks possible. 

The original goal of MoeSocks is to provide extra configurability to standard
shadowsocks, but it has been discarded since the remote is too flaky. 

[shadowsocks]:https://github.com/shadowsocks/shadowsocks 
[shadowsocks in Haskell]:https://github.com/rnons/shadowsocks-haskell



