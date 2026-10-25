// A program's own module wins over the std library unit of the same name.
//
// When every std library module became a unit of the std pack, a bare
// `import random;` started taking the unit path before the resolver looked
// next to the importer, so m390/random.y was ignored and `random.hello` was
// "undefined function". The resolver now checks for a project-local module
// (beside the importer, or in a package's source root) first.

import dice from "./m390/dice.y";

print("roll = " + tostring(dice.roll()));
