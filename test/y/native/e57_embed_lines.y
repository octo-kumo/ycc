// expect-error: 4:7: error: undefined variable 'nope'
embed DATA from "t66_embed.txt";
print(DATA);
print(nope);
