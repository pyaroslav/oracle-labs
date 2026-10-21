whenever sqlerror exit failure
alter pluggable database FREEPDB1 close immediate;
alter pluggable database FREEPDB1 open;
exit
