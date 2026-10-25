// vtdemo -- a screenful that shows what the terminal draws: colours, attributes, line
// drawing, blocks, braille, the alternate screen (vtdemo alt: draws on it, waits a second).
let esc = chr(27);
def sgr(s: str) -> str { esc + "[" + s + "m" };
let rst = sgr("0");

puts(sgr("1") + "Y-OS terminal" + rst + "  " + sgr("4") + "underline" + rst + "  " + sgr("7") + "reverse" + rst + "  " + sgr("2") + "dim" + rst + "  " + sgr("9") + "strike" + rst + "\n");
let i = 0;
let line = "";
while (i < 8) { line += sgr("4" + tostring(i)) + "  "; i = i + 1; };
puts(line + rst + "  ");
i = 0;
line = "";
while (i < 8) { line += sgr("10" + tostring(i)) + "  "; i = i + 1; };
puts(line + rst + "\n");
i = 16;
line = "";
while (i < 232) {
    line += sgr("48;5;" + tostring(i)) + " ";
    i = i + 1;
    if ((i - 16) % 36 == 0) { puts(line + rst + "\n"); line = ""; };
};
i = 0;
line = "";
while (i < 64) {
    let v = i * 4;
    line += sgr("48;2;" + tostring(v) + ";" + tostring(255 - v) + ";128") + " ";
    i = i + 1;
};
puts(line + rst + "\n");
puts("┌──────┬──────┐ ╔══════╦══════╗ ┏━━━━━━┳━━━━━━┓ ╭──────╮\n");
puts("│ box  │ draw │ ║ box  ║ draw ║ ┃ box  ┃ draw ┃ │ arc  │\n");
puts("├──────┼──────┤ ╠══════╬══════╣ ┣━━━━━━╋━━━━━━┫ ╰──────╯\n");
puts("└──────┴──────┘ ╚══════╩══════╝ ┗━━━━━━┻━━━━━━┛\n");
puts("█▇▆▅▄▃▂▁ ░▒▓█ ▏▎▍▌▋▊▉█ ▀▄▌▐ ▖▗▘▙▚▛▜▝▞▟\n");
puts("⠁⠃⠇⡇⣇⣧⣷⣿ ⢀⣀⣤⣶⣿ ⠿⠛⠉ braille: ⣿⣿⣿⡿⠿⠟⠛⠋⠉⠁\n");
puts("Latin-1: áéíóú ñ ç ü ß £ € © ° ± × ÷  arrows: ← ↑ → ↓ • … ✓\n");
puts("wide: 日本語 ✓  tabs:\tA\tB\tC\n");
let a = sgr("38;5;208") + "orange" + rst + " " + sgr("1;32") + "bold green" + rst + " " + sgr("3;36") + "italic cyan" + rst + "\n";
puts(a);
