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
* UDP port forwarding
* TCP per connection throttling (as a side effect of trying to find a bug in the
remote)

Not working
-----------
* Remote is flaky 
* UDP over Socks5 is not implemented
* Four times slower then the original Python implementation

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



