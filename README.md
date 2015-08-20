MoeSocks
========

A socks5 proxy using the client / server architecture.

MoeSocks is greatly inspired by [shadowsocks].

A sample `config.json` file is included in this repository and the cabal
archive.

type `moesocks --help` for help.

Installation
------------

* Need `GHC 7.10.2` and `cabal-install`.
      
  Installing [haskell-platform](https://www.haskell.org/platform/) should be
  sufficient. (Linux users should pick the *Generic* distribution, since
  it's the most up to date)

* Repeat, you need `GHC 7.10.2` exactly, not `7.10.1` or anything else, since
  remote only runs well in `7.10.2`.

* Update packages

        cabal update
* Install

        cabal install moesocks
* Add `~/.cabal/bin` to your `$PATH`, if you haven't already.

Usage
-----
* Edit `config.json` to fit your setup (at least the `remote` and `password`
  fields)
* Start a remote node outside the firewall: 
          
        moesocks --role remote -c config.json
* Start a local node inside the firewall: 
    
        moesocks --role local -c config.json
* Now you have a socks5 proxy running inside the firewall using port 
  `localPort`.

Features
--------
* Socks5 proxy service, obviously
* TCP port forwarding
* UDP port forwarding, for example `-U 5300:8.8.8.8:53`
* TCP per connection throttling (as a side effect of trying to find a bug in the
remote)
* Socks5 service on local can be turned off
* Understand shadowsocks' configuration file

Not working
-----------
* UDP over Socks5 is not implemented
* More then 2 times slower then the original Python implementation (measured at
  20M/s vs 43M/s on an Intel P8800, using the AES-256-CFB method)

Planning features
------------------
* None

Notes
------
* [shadowsocks-haskell] by rnons greatly inspired MoeSocks. 

License
--------
Copyright 2015 Jinjing Wang

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

[shadowsocks]:https://github.com/shadowsocks/shadowsocks 
[shadowsocks-go]:https://github.com/shadowsocks/shadowsocks-go
[shadowsocks-haskell]:https://github.com/rnons/shadowsocks-haskell



