# valgrind.nvim

A neovim plugin for valgrind (memcheck and helgrind) integration.

## Installation

Use your favorite plugin manager. For example, using [vim-plug](https://github.com/junegunn/vim-plug):

```vim
call plug#begin()
Plug 'dlyongemallo/valgrind.nvim'
call plug#end()

require('valgrind').setup()
```

## Usage

```vim
:Valgrind <command>
:ValgrindLoadXml <xml-file>
```
The output will be populated into the quickfix list.

### Examples

```bash
gcc -g -lpthread.c program.c -o ./program
vim program.c
```

```vim
:Valgind --tool=memcheck ./program
:copen
```

Note that `--tool=memcheck` is optional as it is the default tool for valgrind.

Alternatively, you can save the output to a xml file and load it in neovim.

```bash
valgrind --tool=helgrind --xml=yes --xml-file=program.helgrind.xml ./program
vim program.c
```

```vim
:ValgindLoadXml program.helgrind.xml
:copen
```

It is recommended to use the [Trouble](https://github.com/folke/trouble.nvim) plugin to display the quickfix list in a more useful way.

