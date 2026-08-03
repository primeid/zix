# Strings, interpolation and indented strings
let
  name = "ZIX";
  greeting = "hei, ${name}!";
  multi = ''
    Line one
      indented line
    Line three
  '';
in
{ inherit greeting multi; }
