# rpiv-ask-user-question (https://github.com/juicesharp/rpiv-mono): the
# `ask_user_question` tool. Instead of guessing, the model puts a structured
# questionnaire to the user: typed options (single or multi select), an
# optional free-text answer, and previews, in a TUI dialog.
#
# Built from two pinned npm tarballs. The package's one dependency
# (`@juicesharp/rpiv-config`) and a link back to the package itself (for its
# self-import `@juicesharp/rpiv-ask-user-question/events`) go in its own
# node_modules, so both resolve from the store. Pi's
# extension loader aliases the rest (`@earendil-works/pi-*`, `typebox`).
# The optional `@juicesharp/rpiv-i18n` peer is left out: the extension
# imports it dynamically and falls back to English strings without it.
{
  pkgs,
  inputs,
}: let
  inherit (pkgs) lib;
  src = inputs.rpiv-ask-user-question;
  version = (lib.importJSON "${src}/package.json").version;
in
  pkgs.runCommand "pi-rpiv-ask-user-question-${version}" {
    meta = {
      description = "Structured ask-the-user questionnaire tool for Pi";
      homepage = "https://github.com/juicesharp/rpiv-mono/tree/main/packages/rpiv-ask-user-question";
      license = lib.licenses.mit;
    };
  } ''
    # $out is the package itself (Pi loads it through package.json
    # `pi.extensions`), with its dependency and a self-link in node_modules.
    cp -r ${src} $out
    chmod -R u+w $out
    nm=$out/node_modules/@juicesharp
    mkdir -p $nm
    cp -r ${inputs.rpiv-config} $nm/rpiv-config
    ln -s ../.. $nm/rpiv-ask-user-question
  ''
