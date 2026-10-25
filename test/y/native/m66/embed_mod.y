// A module that embeds a file next to ITSELF (t66_embed.y imports it from
// one directory up): embed paths are relative to the file that says them.
embed WORD from "word.txt";

def word() -> str {
    trim(WORD)
};
