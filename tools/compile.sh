#!/bin/sh

em++ -c -I ~/openssl/include -std=c++11 scrypthash.cpp
em++ -c -I ~/openssl/include -std=c++11 scrypt.cpp
em++ -o scrypt.js scrypthash.o scrypt.o -L ~/openssl -lcrypto -lssl

