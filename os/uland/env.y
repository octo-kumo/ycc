// env -- the environment, one NAME=value per line.
import ulib;
ulib.environ().foreach((e) => { puts(e + "\n"); });
