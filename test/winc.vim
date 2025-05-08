import autoload "winc.vim"

let s:assert = themis#helper('assert')
let s:internals = s:winc.Internals_()

let s:suite = themis#suite('CmdKind')

function s:suite.GetIdFromCmd()
  let GetIdFromCmd = { s -> s:internals.GetIdFromCmd(s).name }
  call s:assert.equals(GetIdFromCmd('s'), 'Substitute')
  call s:assert.equals(GetIdFromCmd('sm'), 'Smagic')
  call s:assert.equals(GetIdFromCmd('snomagic'), 'Snomagic')
  call s:assert.equals(GetIdFromCmd('g'), 'Global')
  call s:assert.equals(GetIdFromCmd('vg'), 'Vglobal')
  call s:assert.equals(GetIdFromCmd('v'), 'Vglobal')
  call s:assert.equals(GetIdFromCmd('vimgrep'), 'Vimgrep')
  call s:assert.equals(GetIdFromCmd('lvimgrep'), 'Lvimgrep')
  call s:assert.equals(GetIdFromCmd('vimgrepadd'), 'Vimgrepadd')
  call s:assert.equals(GetIdFromCmd('lvimgrepadd'), 'Lvimgrepadd')
  call s:assert.equals(GetIdFromCmd('sort'), 'Sort')
endfunction

let s:suite = themis#suite('Parser')

function s:suite.__SeparateCmdline__()
  let suite = themis#suite('Range parser')

  function suite.ParseRange()
    let Parser = { line -> s:internals.SeparateCmdline(line)[: 1] }
    call s:assert.equals(Parser('% Cmd'), ['%', ''])
    call s:assert.equals(Parser("'<, '> Cmd"), ["'<", "'>"])
    call s:assert.equals(Parser('/foo/,?bar? Cmd'), ['/foo/', '?bar?'])
    call s:assert.equals(Parser('/foo/+8,?bar?-3 Cmd'), ['/foo/+8', '?bar?-3'])
    call s:assert.equals(Parser('/foo/+8;?bar?-3 Cmd'), ['/foo/+8', '?bar?-3'])
  endfunction
endfunction

function s:suite.__OnCommand__()
  let suite = themis#suite('Get search pattern from command')
  let GetSearchPattern = { line -> s:internals.OnCommand(line).pattern }

  function suite.after_all()
    set magic&
    set ignorecase&
    set smartcase&
  endfunction
endfunction

function s:suite.__ParseSurroundedPattern__()
  let suite = themis#suite('pattern parser')

  function suite.ParseSurroundedPattern()
    let Parser = { line -> s:internals.ParseSurroundedPattern(line) }
    call s:assert.equals(Parser('/hoge/'), 'hoge')
    call s:assert.equals(Parser('/hoge'), 'hoge')
    call s:assert.equals(Parser('/ho\/ge/'), 'ho/ge')
    call s:assert.equals(Parser('/ho\\\/ge/'), 'ho\\/ge')
    call s:assert.equals(Parser(';ho/ge;'), 'ho/ge')
  endfunction
endfunction

let s:suite = themis#suite('Winc')

function s:suite.SeparateOffset()
  let winc = s:internals.WincNew()
  call s:assert.equals(winc.SeparateOffset('.+3'), ['.', '+3'])
  call s:assert.equals(winc.SeparateOffset('/foo+3/+5'), ['/foo+3/', '+5'])
  call s:assert.equals(winc.SeparateOffset('/foo+3\/\\\//+5'), ['/foo+3\/\\\//', '+5'])
  call s:assert.equals(winc.SeparateOffset('?foo\?\\\?+3?+'), ['?foo\?\\\?+3?', '+1'])
endfunction
