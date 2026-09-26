# bankon amnesia: no shell history on disk or in RAM beyond the session, private umask
unset HISTFILE
export HISTFILE=/dev/null HISTSIZE=1000 LESSHISTFILE=-
umask 077
