{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  packages = [
    pkgs.zig
    pkgs.luajit
    pkgs.pkg-config
    pkgs.curl
    pkgs.git
  ];
}
