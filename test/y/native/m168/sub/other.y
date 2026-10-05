// The same shared module, named with a ".." to reach it from here.
import s from "../shared.y";
def doubled() -> long { s.value() * 2 };
export { doubled };
