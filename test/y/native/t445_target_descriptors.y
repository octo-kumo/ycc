import config from "../../../src/y/target.y";

print(config.target_arch_name(), " ", config.target_word());
foreach (name in ["linux", "win", "kernel", "web"]) {
    let info = config.target_info(name);
    print(info.name, " ", info.format, " ", info.threads);
    print(info.runtime);
    print(info.sysregs, " ", info.stack_room, " ", info.stack_base);
};
print(config.target_known("linux"), " ", config.target_known("other"));
print(config.target_names());
res_target = "win";
print(config.target_os(), " ", config.target_is_windows(), " ", config.target_is_kernel());
res_target = "kernel";
print(config.target_os(), " ", config.target_is_windows(), " ", config.target_is_kernel());
