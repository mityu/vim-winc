vim9script noclear
# Requires Vim >= 9.1.0219.

var FuncWrapper: func(): void

# These functions are ported from thinca/ambicmd.vim, thanks!
def EscapeForVeryMagic(str: string): string
  return escape(str, '\.^$?*+~()[]{@|=&')
enddef

def PATTERN_NON_ESCAPE_CHAR(char: string, force_escape: bool = true): string
  return '\v%(%(\_^|[^\\])%(\\\\)*)@<=' ..
     (force_escape ? EscapeForVeryMagic(char) : char)
enddef

def GenerateRangeSpecifierPattern(): string
  const range_factor_search = printf('%%(/.*%s|\?.*%s)',
          PATTERN_NON_ESCAPE_CHAR('/'), PATTERN_NON_ESCAPE_CHAR('?'))
  const range_factors = [
    '\d+',
    '[.$%]',
    "'.",
    range_factor_search .. '%(' .. range_factor_search .. ')?',
    '\\[/?&]',
  ]
  return '%(' .. join(range_factors, '|') .. ')%(\s*[+-]\d+)?'
enddef

def GenerateCommandParser(): string
  const rangeSpacifier = GenerateRangeSpecifierPattern()
  const rangeDelimiter = '\s*[,;]\s*'
  return $'\v^\s*%(({rangeSpacifier})%({rangeDelimiter}({rangeSpacifier}))?)?\s*(\a+)\s*(!?)\s*(.*)'
enddef

def IsValidRegexp(regexp: string): bool
  if regexp ==# ''
    return false
  endif
  try
    eval '' =~# regexp
  catch
    return false
  endtry
  return true
enddef

class SearchState
  public var searchFlags: string
  public var searchFlagsTurn: string
  public var cursorLine: number
  public var bottomLine: number
  public var initialCursorPos: list<number>
  public var wrapscan: bool
endclass

class SearchOptions
  public var ignoreCase: bool
  public var magic: bool
endclass

enum CmdKind
  None,
  Others,
  Substitute,
  Smagic,
  Snomagic,
  Global,
  Vglobal,
  Vimgrep,
  Lvimgrep,
  Vimgrepadd,
  Lvimgrepadd,
  Sort

  static def GetIdFromCmd(cmd: string): CmdKind
    const table = {
      ['s%[ubstitute]']: Substitute,
      ['sm%[agic]']: Smagic,
      ['sno%[magic]']: Snomagic,
      ['g%[lobal]']: Global,
      ['v%[global]']: Vglobal,
      ['vim%[grep]']: Vimgrep,
      ['lvim%[grep]']: Lvimgrep,
      ['vimgrepa%[dd]']: Vimgrepadd,
      ['lvimgrepa%[dd]']: Lvimgrepadd,
      ['sor%[t]']: Sort,
    }
    for [p, id] in items(table)
      if cmd =~# $'\v^{p}>'
        return id
      endif
    endfor
    return Others
  enddef
endenum

class CmdState
  public var range1: string
  public var range2: string
  public var pattern: string
  public var command: CmdKind
endclass

class Parser
  static var PATTERN_COMMAND_PARSER  = GenerateCommandParser()

  static var MethodOnSearch = 1
  static var MethodOnCommand = 2

  var Parser: func(string): CmdState

  def new(method: number)
    if method == MethodOnSearch
      this.Parser = (p: string): CmdState => Parser.OnSearch(p)
    elseif method == MethodOnCommand
      this.Parser = (p: string): CmdState => Parser.OnCommand(p)
    else
      echoerr 'Internal error: Parser.new(): Invalid method: ' .. method
    endif
  enddef

  def Parse(line: string): CmdState
    return call(this.Parser, [line])
  enddef

  static def OnSearch(line: string): CmdState
    var s = CmdState.new()
    s.range1 = '%'
    s.range2 = ''
    s.pattern = line->Parser._completeSearchOptions(CmdKind.None)
    s.command = CmdKind.None
    return s
  enddef

  # Target commands:
  #  :s[ubstitute], :sm[agic], :sno[magic]
  #  :g[lobal][!], :v[global]
  #  :vim[grep], :lvim[grep], :vimgrepa[dd], :lvimgrepa[dd] (no range)
  #  :vim[grep]!, :lvim[grep]!, :vimgrepa[dd]!, :lvimgrepa[dd]! (no range)
  #  :sor[t]
  static def OnCommand(line: string): CmdState
    var [range1, range2, cmd, _, arg] = Parser.SeparateCmdline(line)
    if cmd =~# '\v^%(g%[lobal]|v%[global]|s%[ubstitute]|sm%[agic]|sno%[magic])$'
      var s = CmdState.new()
      s.range1 = range1
      s.range2 = range2
      s.command = CmdKind.GetIdFromCmd(cmd)
      s.pattern = Parser.ParseSurroundedPattern(arg)->Parser._completeSearchOptions(s.command)
      return s
    else
      return null_object
    endif
  enddef

  # Split given command-line into
  #  - range start
  #  - range end
  #  - command
  #  - bang
  #  - command arguments
  static def SeparateCmdline(line: string): list<string>
    var matched = matchlist(line, PATTERN_COMMAND_PARSER)[1 : 5]
    if empty(matched)
      return ['', '', '', '', '']
    endif
    return matched
  enddef

  # Parse /{pattern}/ and returns {pattern}.
  static def ParseSurroundedPattern(pattern: string): string
    if strlen(pattern[0]) != 1
      return ''
    endif
    var delimiter = pattern[0]
    var closingDelimiter = PATTERN_NON_ESCAPE_CHAR(delimiter)
    var nonEscapedDelimiter =
      PATTERN_NON_ESCAPE_CHAR('\\' .. EscapeForVeryMagic(delimiter), false)
    var idx = match(pattern, closingDelimiter, 1)
    var extracted = idx == -1 ? pattern[1 :] : strpart(pattern, 1, idx - 1)
    if extracted ==# ''
      return @/
    endif
    return extracted->substitute(nonEscapedDelimiter, delimiter, 'g') # \/ -> /
  enddef

  static def _composeSearchOptions(pattern: string, kind: CmdKind): SearchOptions
    var opts = SearchOptions.new()

    opts.ignoreCase = &ignorecase || (&smartcase && pattern =~# '\u')

    opts.magic = &magic
    if kind == CmdKind.Smagic
      opts.magic = true
    elseif kind == CmdKind.Snomagic
      opts.magic = false
    endif

    return opts
  enddef

  static def _completeSearchOptions(patternGiven: string, kind: CmdKind): string
    if !IsValidRegexp(patternGiven)
      return patternGiven
    endif

    const opts = _composeSearchOptions(patternGiven, kind)
    var pattern = patternGiven

    if !opts.magic
      pattern = '\M' .. pattern
    endif

    if opts.ignoreCase
      pattern = '\c' .. pattern
    else
      pattern = '\C' .. pattern
    endif
    return pattern
  enddef
endclass

class Highlighter
  var winID: number
  var bufnr: number
  var winlist: list<number>
  var matchIDs: list<list<number>>

  def new(winID: number)
    this.winID = winID
    this.bufnr = winbufnr(winID)
    this.winlist = win_findbuf(this.bufnr)
  enddef

  def Highlight(line1: number, line2: number, patternGiven: string)
    this.ClearHighlight()

    var pattern = patternGiven
    if !(line1 == 1 && line('$', this.winID) == line2)
      if pattern =~# '\\$' && !IsValidRegexp($'\%({pattern}\v)')
        # Escape single backslash at the end of pattern to avoid E53 error.
        pattern ..= '\'
      endif
      pattern = $'\v%(%>{line1}l|%{line1}l)%(\m{pattern}\v)%(%<{line2}l|%{line2}l)'
    endif

    for winID in this.winlist
      const matchID = matchadd('Search', pattern, 10, -1, {window: winID})
      this.matchIDs->add([winID, matchID])
    endfor
  enddef

  def ClearHighlight()
    if !empty(this.matchIDs)
      for [winID, matchID] in this.matchIDs
        matchdelete(matchID, winID)
      endfor
      this.matchIDs = []
    endif
  enddef
endclass

class Winc
  static var DoIncsearchExec: func()
  static var TerminateExec: func()

  var _winID: number
  var _initialCurPos: list<number>
  var _initialFirstline: number
  var _restoreCurPosFunc: func(): void
  var _highlighter: Highlighter
  var _parser: Parser
  var _searchForward: bool

  def new()
    const cmdwintype = getcmdwintype()
    if !(cmdwintype ==# ':' || cmdwintype ==# '/' || cmdwintype ==# '?')
      return
    endif

    this._winID = win_getid(winnr('#'))
    this._initialCurPos = getcurpos(this._winID)
    this._initialFirstline = this.Line('w0')
    this._restoreCurPosFunc = () => {
      setpos('.', this._initialCurPos)
      const firstline = this.Line('w0')
      normal! zz
      while this.Line('w0') > this._initialFirstline
        execute "normal! \<C-y>"
      endwhile
      while this.Line('w0') < this._initialFirstline
        execute "normal! \<C-e>"
      endwhile
    }
    this._highlighter = Highlighter.new(this._winID)
    this._parser = Parser.new(
      cmdwintype ==# ':' ? Parser.MethodOnCommand : Parser.MethodOnSearch)
    this._searchForward = cmdwintype !=# '?'

    DoIncsearchExec = () => this.DoIncsearch()
    TerminateExec = () => this.Terminate()
    augroup winc-incsearch
      autocmd!
      autocmd TextChanged,TextChangedI,CursorMoved * call(Winc.DoIncsearchExec, [])
      autocmd CmdwinLeave * ++once call(Winc.TerminateExec, [])
    augroup END
  enddef

  def Terminate()
    augroup winc-incsearch
      autocmd!
    augroup END
    this._highlighter.ClearHighlight()
    this.CallInWindow(this._restoreCurPosFunc)
  enddef

  def DoIncsearch()
    const cmdState = this._parser.Parse(getline('.'))
    this.CallInWindow(this._restoreCurPosFunc)
    if cmdState == null_object || cmdState.pattern ==# '' || !IsValidRegexp(cmdState.pattern)
      this.CallInWindow(() => this._highlighter.ClearHighlight())
      return
    endif

    # TODO: Support [count] argument of :substitute
    const [line1, line2] = this.EvalRegion(cmdState)
    this._highlighter.Highlight(line1, line2, cmdState.pattern)

    # TODO: Highlight first match.
    const changeSearchStartPos = cmdState.command != CmdKind.None
    const searchflags = this._searchForward ? 'c' : 'cbz'
    var stopline = 0

    if changeSearchStartPos
      if this._searchForward
        this.EvalInWindow(() => cursor(line1, 0))
        stopline = line2
      else
        this.EvalInWindow(() => execute($'keepjumps normal! {line2}G$'))
        stopline = line1
      endif
    endif

    const matchedline = this.EvalInWindow(() =>
      search(cmdState.pattern, searchflags, stopline, 500))
    if matchedline != 0
      if matchedline < line('w0', this._winID) || matchedline > line('w$', this._winID)
        this.EvalInWindow(() => execute('normal! zz'))
      endif
      redraw
    elseif changeSearchStartPos
      # If there's no match and cursor position is changed above, restore
      # cursor position.
      this.CallInWindow(this._restoreCurPosFunc)
    endif

    # TODO: Restore view if changed.
    # if getcurpos() == this._initialCurPos
    # endif
  enddef

  # Evaluate region string, such as %, '< and '>, into line numbers.
  def EvalRegion(state: CmdState): list<number>
    if state.range1 ==# '%'
      return [1, this.Line('$')]
    elseif state.range1 ==# '' && state.range2 ==# ''
      return this.GetRegionWhenUnspecified(state)
    endif

    const line1 = this.EvalRegionOne(state.range1)
    const line2 = this.EvalRegionOne(state.range2)
    if line1 == -1 || line2 == -1
      # Fallback to current line.
      return this.GetRegionWhenUnspecified(state)
    endif
    if line1 <= line2
      return [line1, line2]
    else
      return [line2, line1]
    endif
  enddef

  def GetRegionWhenUnspecified(state: CmdState): list<number>
    # The current cursor line will be the target line except for the :global
    # command.
    if state.command == CmdKind.Global
      return [1, this.Line('$')]
    else
      return [this.Line('.'), this.Line('.')]
    endif
  enddef

  # Evaluate region such as '<, $, \&.  Returns -1 when failed.
  def EvalRegionOne(range: string): number
    var [pat, offset] = this.SeparateOffset(range)
    var line: number
    if pat ==# ''
      line = this.Line('.')  # When range is '+3', then [pat = '', offset = '+3']
    elseif pat ==# '$'
      line = this.Line('$')
    elseif pat ==# '.'
      line = this.Line('.')
    elseif pat ==# '^\d\+$'
      line = eval(pat)
    elseif strlen(pat) == 2 && pat[0] ==# "'"
      line = this.Line(pat)  # mark
      if line == 0  # Mark is not set on current buffer.
        return -1
      endif
    # elseif pat ==# '\/'  # TODO:
    # elseif pat ==# '\?'
    # elseif pat ==# '\&'
    # elseif pat[0] ==# '/'
    # elseif pat[0] ==# '?'
    else
      return -1
    endif

    if offset !=# ''
      return line + eval(offset)
    else
      return line
    endif
  enddef

  def SeparateOffset(range: string): list<string>
    var idx = match(range, '\v\zs\s*%([+-]\s*\d*)?\s*$')
    var pattern = strpart(range, 0, idx)
    var offset = range[idx :]->substitute('\s', '', 'g')
    if offset ==# '+' || offset ==# '-'
      offset = offset .. '1' # Normalize offset
    endif
    return [pattern, offset]
  enddef

  def Line(expr: string): number
    return line(expr, this._winID)
  enddef

  def CallInWindow(F: func(): void)
    FuncWrapper = F
    win_execute(this._winID, 'FuncWrapper()')
    FuncWrapper = null_function
  enddef

  def EvalInWindow(F: func(): any): any
    var retval: any
    FuncWrapper = () => {
      retval = F()
    }
    win_execute(this._winID, 'FuncWrapper()')
    FuncWrapper = null_function
    return retval
  enddef
endclass

var wincObj: Winc
export def Setup()
  wincObj = Winc.new()
enddef

export def Internals_(): dict<any>
  return {
    GetIdFromCmd: CmdKind.GetIdFromCmd,
    SeparateCmdline: Parser.SeparateCmdline,
    WincNew: () => Winc.new(),
    OnCommand: Parser.OnCommand,
    ParseSurroundedPattern: Parser.ParseSurroundedPattern,
  }
enddef
