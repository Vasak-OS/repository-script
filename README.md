# repository-script

A script that allows you to generate repositories for VasakOS (pacman/ archilinux)

## How to "install" basis

Adding a third-party repository (like this one) is easy.  Just add the following lines to the end of /etc/pacman.conf :

```conf
[basis]
SigLevel = Optional DatabaseOptional
Server = https://repo.vasak.net.ar/basis/$arch
```

