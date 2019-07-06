let s:cpoptions_save = &cpoptions
set cpoptions&vim

function! s:let_default(name, value) abort
  if !exists(a:name)
    let {a:name} = a:value
  endif
endfunction

call s:let_default('g:brownie#info', {})
call s:let_default('g:brownie#extra_imports', {})
call s:let_default('s:FALSE', 0)
call s:let_default('s:TRUE', !s:FALSE)
call s:let_default('s:context', {
      \ 'kind': '',
      \ 'path': '',
      \ 'script': [],
      \ 'contents': [],
      \ 'extract_pos': {'line': 0, 'col': 0},
      \ 'indent': 0,
      \ 'original_text': [],
      \ 'is_sourcing': 0,
      \ })
call s:let_default('s:available_kinds', ['template', 'snippet'])
call s:let_default('s:all_filetypes', '_')
call s:let_default('s:options_shelter', {
      \ 'shelter_': {},
      \ 'bufnr_': -1,
      \ })

function! s:options_shelter.new() abort
  return deepcopy(self)
endfunction

function! s:options_shelter.save(options) abort
  if !empty(self.shelter_)
    call s:error_msg('Options have NOT been restored yet')
  endif
  let self.bufnr_ = brownie#get_current_bufnr()
  for option in a:options
    let option = '&' . option
    let self.shelter_[option] = getbufvar(self.bufnr_, option)
  endfor
endfunction

function! s:options_shelter.restore() abort
  if self.bufnr_ == -1
    return
  endif
  for option in keys(self.shelter_)
    call setbufvar(self.bufnr_, option, self.shelter_[option])
  endfor
  let self.shelter_ = {}
endfunction

call s:let_default('s:cursor_marker', '{{_cursor_}}')
call s:let_default('s:viewer', {
      \ 'need_restore_buffer': s:FALSE,
      \ 'options_shelter': s:options_shelter.new(),
      \ 'template_location': {'begin': 0, 'end': 0},
      \ })

function! s:viewer.ready() abort
  call self.options_shelter.save([
       \ 'cursorline', 'cursorcolumn', 'conceallevel', 'concealcursor'])
  setlocal nocursorline nocursorcolumn conceallevel=3 concealcursor=nicv

  let self.need_restore_buffer = s:FALSE
  call self.update_template_location()
  call self.update_highlight_region()
  " Conceal marker for cursor.
  execute 'syntax match brownieMarkerCursor'
        \ 'conceal cchar=| contained containedin=brownieTemplateLocation'
        \ string(s:cursor_marker)
  highlight default link browniePlaceHolder TODO
endfunction

function! s:viewer.update_screen() abort
  call self.restore_buffer_lines()
  call self.update_template_location()
  call self.paste_template()
  call self.update_highlight_region()
  redraw!
endfunction

function! s:viewer.restore_buffer_lines() abort
  if !self.need_restore_buffer
    return
  endif
  let loc = self.template_location
  if loc.begin >= 1
    if (loc.end - loc.begin) >= 2
      execute 'silent' loc.begin + 1 . ',' . loc.end 'delete _'
    endif
    call setline(loc.begin, join(s:context.original_text, ''))
    call cursor(s:context.extract_pos.line, s:context.extract_pos.col)
  endif
endfunction

function! s:viewer.update_template_location()
  let loc = self.template_location
  let loc.begin = s:context.extract_pos.line
  let loc.end = loc.begin + len(s:context.contents) - 1
endfunction

function! s:viewer.paste_template() abort
  let loc = self.template_location
  let contents = copy(s:context.contents)
  let contents[0] = s:context.original_text[0] . contents[0]
  let contents[-1] .= s:context.original_text[1]

  let newline_count = len(contents) - 1
  if newline_count
    call append(loc.begin, repeat([''], newline_count))
  endif

  call setline(loc.begin, contents)
  if ((loc.end - loc.begin) >= 1) && s:context.indent
    " Make sure indent.
    execute 'silent' loc.begin + 1 . ',' . loc.end repeat('>', s:context.indent)
  endif
  let self.need_restore_buffer = s:TRUE
endfunction

function! s:viewer.update_highlight_region() abort
  " Define region of a template/snippet.
  if hlexists('brownieTemplateLocation')
    syntax clear brownieTemplateLocation
  endif
  execute 'syntax region brownieTemplateLocation'
        \ 'start=/\%' . self.template_location.begin . 'l/'
        \ 'end=/\%' . self.template_location.end . 'l.*$/'
        \ 'contains=brownieMarkerCursor,browniePlaceHolder'
endfunction

function! s:viewer.highlight_pattern(pattern) abort
  syntax clear browniePlaceHolder
  execute 'syntax match browniePlaceHolder /' . a:pattern . '/'
        \ 'contained containedin=brownieTemplateLocation'
  redraw!
endfunction

function! s:viewer.finish() abort
  let self.need_restore_buffer = s:FALSE
  call self.options_shelter.restore()
  syntax clear brownieTemplateLocation
  syntax clear brownieMarkerCursor
  syntax clear browniePlaceHolder
endfunction

call s:let_default('s:extractor', {
      \ 'is_active_': s:FALSE,
      \ 'did_update_screen_': s:FALSE,
      \ })

function! s:extractor.ready(template_path) abort
  if self.is_active_
    return s:FALSE
  endif
  let self.is_active_ = s:TRUE

  let s:context.path = a:template_path
  let s:context.extract_pos.line = line('.')
  let s:context.extract_pos.col = col('.')
  let s:context.indent = s:indent(s:context.extract_pos.line)
  let s:context.original_text = s:str_divide_pos(
        \ getline(s:context.extract_pos.line),
        \ s:context.extract_pos.col - (mode() ==# 'i' ? 1 : 0))

  " Separate file contents into a script and a template/snippet text.
  let contents = readfile(s:context.path)
  let idx = -1
  let had_finish = 0
  for line in contents
    if line =~# '\v^%([^:].*)$|^:\s*fini%[sh]>'
      let had_finish = (line =~# '\v^:\s*fini%[sh]>')
      break
    endif
    let idx += 1
  endfor
  if idx != -1
    let s:context.script = remove(contents, 0, idx)
  endif
  if had_finish
    call remove(contents, 0)
  endif
  if s:use_softtab()
    " Convert from hardtab indentation to softtab indentation.
    let matcher = '\v%(^%(\s)*)@<=\s'
    let indent = repeat(' ', shiftwidth())
    call map(contents, 'substitute(v:val, matcher, indent, "g")')
  endif
  let s:context.contents = contents

  call s:viewer.ready()
  return s:TRUE
endfunction

function! s:extractor.process() abort
  call self.source_script()
endfunction

function! s:extractor.finish() abort
  if !self.is_active_
    return
  endif
  call s:viewer.update_screen()
  call s:viewer.finish()
  call self.set_cursor_pos()
  let self.is_active_ = s:FALSE
endfunction

function! s:extractor.source_script() abort
  if empty(s:context.script)
    call s:doautocmd('source-pre')
    call s:doautocmd('source-post')
    return s:FALSE
  endif
  let script_file = tempname() . '.vim'
  try
    if writefile(s:context.script, script_file) == -1
      call s:throw('failed to write file: ' . script_file)
    endif
    let s:context.is_sourcing = s:TRUE
    call s:doautocmd('source-pre')
    source `=script_file`
    call s:doautocmd('source-post')
  catch
    call s:error_msg(v:exception)
  finally
    let s:context.is_sourcing = s:FALSE
    if getftype(script_file) ==# 'file'
      call delete(script_file)
    endif
  endtry
endfunction

function! s:extractor.set_cursor_pos() abort
  call cursor(s:context.extract_pos.line, s:context.extract_pos.col)
  if stridx(join(s:context.contents, "\n"), s:cursor_marker) != -1
    " Jump to cursor marker.
    call search(s:cursor_marker, 'cW')
    let curpos = getpos('.')
    normal! "_da{
    call setpos('.', curpos)
  endif
endfunction

function! s:extract_impl(template_path) abort
  call s:doautocmd('extract-pre')
  if s:context.kind ==# 'template' && !brownie#is_buffer_empty()
    call s:error_msg('cannot extract template here.')
    return s:FALSE
  endif
  if !s:extractor.ready(a:template_path)
    return s:FALSE
  endif
  try
    call s:extractor.process()
  finally
    call s:extractor.finish()
    call s:doautocmd('extract-post')
    return s:TRUE
  endtry
endfunction

call s:let_default('s:scriptfuncs', {'impl': {}})

function! s:scriptfuncs.call(func, ...) abort
  if !s:context.is_sourcing
    call s:error_msg('only available while sourcing scripts.')
    return s:FALSE
  endif
  return call(self.impl[a:func], a:000)
endfunction

" Replace text in the template/snippet.
function! s:scriptfuncs.impl.replace(from, to) abort
  let s:context.contents = split(
        \ substitute(join(s:context.contents, "\n"), a:from, a:to, 'g'),
        \ "\n")
endfunction

function! s:scriptfuncs.impl.input(prompt, ...) abort
  try
    return call('input', [a:prompt] + a:000)
  catch /\C^Vim:Interrupt$/
    return ''
  catch
    call s:error_msg(v:exception)
    return ''
  endtry
endfunction

function! s:scriptfuncs.impl.highlight(pattern) abort
  call s:viewer.highlight_pattern(a:pattern)
  call s:viewer.update_screen()
endfunction

"  Wrapper functions for s:scriptfuncs.impl.*
function! brownie#replace(from, to) abort
  call s:scriptfuncs.call('replace', a:from, a:to)
endfunction

function! brownie#input(prompt, ...) abort
  return call(s:scriptfuncs.call, ['input', a:prompt] + a:000)
endfunction
function! brownie#highlight(pattern) abort
  call s:scriptfuncs.call('highlight', a:pattern)
endfunction

function! brownie#list(filetype, kind) abort
  return uniq(sort(map(
        \ s:list_templates(a:filetype, a:kind, '*'),
        \ 's:get_template_name(v:val)')))
endfunction

function! brownie#extract(filetype, kind, name) abort
  let templates = s:list_templates(a:filetype, a:kind, a:name)
  if empty(templates)
    call s:error_msg(a:kind . ' not found: ' . a:name)
    return s:FALSE
  endif
  let s:context.kind = a:kind
  return s:extract_impl(templates[-1])
endfunction

function! brownie#exists(filetype, kind, name) abort
  return !empty(s:list_templates(a:filetype, a:kind, a:name))
endfunction

function!  brownie#get_current_bufnr() abort
  return bufnr(s:is_cmdwin() ? '#' : '%')
endfunction

function! brownie#is_buffer_empty(...) abort
  let bufnr = exists('a:1') ? bufnr(a:1) : brownie#get_current_bufnr()
  if bufnr('%') == bufnr
    return (line('$') == 1) && (getline(1) ==# '')
  else
    return getbufline(bufnr, 1, '$') == ['']
  endif
  return s:FALSE  " You never reach here.
endfunction

function! s:list_templates(filetype, kind, template_name) abort
  let files = []
  let filetypes = [s:all_filetypes]
  let filetypes += a:filetype ==# '' ? [] : [a:filetype]
  let filetypes += get(g:brownie#extra_imports, a:filetype, [])
  for filetype in filetypes
    call extend(files, s:list_files(filetype, a:kind, a:template_name))
  endfor
  return files
endfunction

function! s:list_files(filetype, kind, template_name) abort
  let dirs = s:globpath(join(s:get_template_dirs(), ','), a:filetype . '/')
  let dirs += map(copy(dirs), 'v:val . a:kind')
  return s:globpath(join(dirs, ','), a:template_name . '.*')
endfunction

function! s:get_template_name(filepath) abort
  return fnamemodify(a:filepath, ':p:t:r')
endfunction

function! s:is_cmdwin() abort
  return getcmdwintype() !=# ''
endfunction

function! s:get_template_dirs() abort
  return get(g:, 'brownie_template_dirs', [])
endfunction

" globpath(), but both 'suffixes' and 'wildignore' don't have any effects to
" the results, and list is returned.
function! s:globpath(path, expr) abort
  return globpath(a:path, a:expr, s:TRUE, s:TRUE)
endfunction

function! s:use_softtab() abort
  return getbufvar(brownie#get_current_bufnr(), '&expandtab')
endfunction

function! s:indent(line) abort
  return indent(a:line) / (s:use_softtab() ? shiftwidth() : 1)
endfunction

function! s:str_divide_pos(string, position) abort
  return [strpart(a:string, 0, a:position), a:string[a:position :]]
endfunction

function! s:throw(exception) abort
  throw 'brownie: ' . a:exception
endfunction

function! s:doautocmd(kind, ...) abort
  try
    execute 'doautocmd User brownie-' . a:kind
  catch
    call s:error_msg(get(a:000, 0, '') . v:exception)
  endtry
endfunction

function! s:error_msg(msg) abort
  echohl Error
  echomsg '[brownie]' a:msg
  echohl NONE
endfunction

augroup brownie-dummy
  autocmd!
  autocmd User brownie-extract-pre  silent
  autocmd User brownie-extract-post silent
  autocmd User brownie-source-pre   silent
  autocmd User brownie-source-post  silent
augroup END

" For themis.vim
function! s:script_variables() abort
  return s:
endfunction
let s:plugin_root = expand('<sfile>:h:h')


let &cpoptions = s:cpoptions_save
unlet s:cpoptions_save
