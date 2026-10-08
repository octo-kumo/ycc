// A project-local module named like a std library unit (random). Imported
// bare from m390/dice.y, it must be THIS file that is spliced: a module next to
// the importer shadows the std unit of the same name (native.y res_local_mod).

def hello() -> long {
    42
}
