// w102_feature_check: the page must refuse a browser without WebAssembly
// tail calls before it fetches the module (S13). The check is injected by
// src/web/test/browser.test.mjs; this fixture is the program the page would run.
puts("feature check survived\n");
