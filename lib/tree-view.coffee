path = require 'path'
shell = require 'shell'

_ = require 'underscore-plus'
{BufferedProcess, CompositeDisposable} = require 'atom'
{$, View} = require 'atom-space-pen-views'
fs = require 'fs-plus'

AddDialog = null  # Defer requiring until actually needed
MoveDialog = null # Defer requiring until actually needed
CopyDialog = null # Defer requiring until actually needed
Minimatch = null  # Defer requiring until actually needed

Directory = require './directory'
DirectoryView = require './directory-view'
FileView = require './file-view'
LocalStorage = window.localStorage

toggleConfig = (keyPath) ->
  atom.config.set(keyPath, not atom.config.get(keyPath))

module.exports =
class TreeView extends View
  panel: null

  @content: ->
    @div class: 'tree-view-resizer tool-panel', 'data-show-on-right-side': atom.config.get('tree-view.showOnRightSide'), =>
      @div class: 'tree-view-scroller', outlet: 'scroller', =>
        @ol class: 'tree-view full-menu list-tree has-collapsable-children focusable-panel', tabindex: -1, outlet: 'list'
      @div class: 'tree-view-resize-handle', outlet: 'resizeHandle'

  initialize: (state) ->
    @disposables = new CompositeDisposable
    @focusAfterAttach = false
    @roots = []
    @scrollLeftAfterAttach = -1
    @scrollTopAfterAttach = -1
    @selectedPath = null
    @ignoredPatterns = []

    @handleEvents()

    process.nextTick =>
      @onStylesheetsChanged()
      onStylesheetsChanged = _.debounce(@onStylesheetsChanged, 100)
      @disposables.add atom.styles.onDidAddStyleElement(onStylesheetsChanged)
      @disposables.add atom.styles.onDidRemoveStyleElement(onStylesheetsChanged)
      @disposables.add atom.styles.onDidUpdateStyleElement(onStylesheetsChanged)

    @updateRoots(state.directoryExpansionStates)
    @selectEntry(@roots[0])

    @selectEntryForPath(state.selectedPath) if state.selectedPath
    @focusAfterAttach = state.hasFocus
    @scrollTopAfterAttach = state.scrollTop if state.scrollTop
    @scrollLeftAfterAttach = state.scrollLeft if state.scrollLeft
    @attachAfterProjectPathSet = state.attached and _.isEmpty(atom.project.getPaths())
    @width(state.width) if state.width > 0
    @attach() if state.attached

  attached: ->
    @focus() if @focusAfterAttach
    @scroller.scrollLeft(@scrollLeftAfterAttach) if @scrollLeftAfterAttach > 0
    @scrollTop(@scrollTopAfterAttach) if @scrollTopAfterAttach > 0

  detached: ->
    @resizeStopped()

  serialize: ->
    directoryExpansionStates: new ((roots) ->
      @[root.directory.path] = root.directory.serializeExpansionState() for root in roots
      this)(@roots)
    selectedPath: @selectedEntry()?.getPath()
    hasFocus: @hasFocus()
    attached: @panel?
    scrollLeft: @scroller.scrollLeft()
    scrollTop: @scrollTop()
    width: @width()

  deactivate: ->
    root.directory.destroy() for root in @roots
    @disposables.dispose()
    @detach() if @panel?

  handleEvents: ->
    @on 'dblclick', '.tree-view-resize-handle', =>
      @resizeToFitContent()
    @on 'click', '.entry', (e) =>
      # This prevents accidental collapsing when a .entries element is the event target
      return if e.target.classList.contains('entries')

      @entryClicked(e) unless e.shiftKey or e.metaKey or e.ctrlKey
    @on 'mousedown', '.entry', (e) =>
      @onMouseDown(e)

    @on 'mousedown', '.tree-view-resize-handle', (e) => @resizeStarted(e)

    atom.commands.add @element,
     'core:move-up': @moveUp.bind(this)
     'core:move-down': @moveDown.bind(this)
     'core:page-up': => @pageUp()
     'core:page-down': => @pageDown()
     'core:move-to-top': => @scrollToTop()
     'core:move-to-bottom': => @scrollToBottom()
     'tree-view:expand-directory': => @expandDirectory()
     'tree-view:recursive-expand-directory': => @expandDirectory(true)
     'tree-view:collapse-directory': => @collapseDirectory()
     'tree-view:recursive-collapse-directory': => @collapseDirectory(true)
     'tree-view:open-selected-entry': => @openSelectedEntry(true)
     'tree-view:open-selected-entry-right': => @openSelectedEntryRight()
     'tree-view:open-selected-entry-left': => @openSelectedEntryLeft()
     'tree-view:open-selected-entry-up': => @openSelectedEntryUp()
     'tree-view:open-selected-entry-down': => @openSelectedEntryDown()
     'tree-view:move': => @moveSelectedEntry()
     'tree-view:copy': => @copySelectedEntries()
     'tree-view:cut': => @cutSelectedEntries()
     'tree-view:paste': => @pasteEntries()
     'tree-view:copy-full-path': => @copySelectedEntryPath(false)
     'tree-view:show-in-file-manager': => @showSelectedEntryInFileManager()
     'tree-view:open-in-new-window': => @openSelectedEntryInNewWindow()
     'tree-view:copy-project-path': => @copySelectedEntryPath(true)
     'tool-panel:unfocus': => @unfocus()
     'tree-view:toggle-vcs-ignored-files': -> toggleConfig 'tree-view.hideVcsIgnoredFiles'
     'tree-view:toggle-ignored-names': -> toggleConfig 'tree-view.hideIgnoredNames'
     'tree-view:remove-project-folder': (e) => @removeProjectFolder(e)

    [0..8].forEach (index) =>
      atom.commands.add @element, "tree-view:open-selected-entry-in-pane-#{index + 1}", =>
        @openSelectedEntryInPane index

    @disposables.add atom.workspace.onDidChangeActivePaneItem =>
      @selectActiveFile()
    @disposables.add atom.project.onDidChangePaths =>
      @updateRoots()
    @disposables.add atom.config.onDidChange 'tree-view.hideVcsIgnoredFiles', =>
      @updateRoots()
    @disposables.add atom.config.onDidChange 'tree-view.hideIgnoredNames', =>
      @updateRoots()
    @disposables.add atom.config.onDidChange 'core.ignoredNames', =>
      @updateRoots() if atom.config.get('tree-view.hideIgnoredNames')
    @disposables.add atom.config.onDidChange 'tree-view.showOnRightSide', ({newValue}) =>
      @onSideToggled(newValue)
    @disposables.add atom.config.onDidChange 'tree-view.sortFoldersBeforeFiles', =>
      @updateRoots()

  toggle: ->
    if @isVisible()
      @detach()
    else
      @show()

  show: ->
    @attach()
    @focus()

  attach: ->
    return if _.isEmpty(atom.project.getPaths())

    @panel ?=
      if atom.config.get('tree-view.showOnRightSide')
        atom.workspace.addRightPanel(item: this)
      else
        atom.workspace.addLeftPanel(item: this)

  detach: ->
    @scrollLeftAfterAttach = @scroller.scrollLeft()
    @scrollTopAfterAttach = @scrollTop()

    # Clean up copy and cut localStorage Variables
    LocalStorage['tree-view:cutPath'] = null
    LocalStorage['tree-view:copyPath'] = null

    @panel.destroy()
    @panel = null
    @unfocus()

  focus: ->
    @list.focus()

  unfocus: ->
    atom.workspace.getActivePane().activate()

  hasFocus: ->
    @list.is(':focus') or document.activeElement is @list[0]

  toggleFocus: ->
    if @hasFocus()
      @unfocus()
    else
      @show()

  entryClicked: (e) ->
    entry = e.currentTarget
    isRecursive = e.altKey or false
    switch e.originalEvent?.detail ? 1
      when 1
        @selectEntry(entry)
        @openSelectedEntry(false) if entry instanceof FileView
        entry.toggleExpansion(isRecursive) if entry instanceof DirectoryView
      when 2
        if entry instanceof FileView
          @unfocus()
        else if DirectoryView
          entry.toggleExpansion(isRecursive)

    false

  resizeStarted: =>
    $(document).on('mousemove', @resizeTreeView)
    $(document).on('mouseup', @resizeStopped)

  resizeStopped: =>
    $(document).off('mousemove', @resizeTreeView)
    $(document).off('mouseup', @resizeStopped)

  resizeTreeView: ({pageX, which}) =>
    return @resizeStopped() unless which is 1

    if atom.config.get('tree-view.showOnRightSide')
      width = @outerWidth() + @offset().left - pageX
    else
      width = pageX - @offset().left
    @width(width)

  resizeToFitContent: ->
    @width(1) # Shrink to measure the minimum width of list
    @width(@list.outerWidth())

  loadIgnoredPatterns: ->
    @ignoredPatterns.length = 0
    return unless atom.config.get('tree-view.hideIgnoredNames')

    Minimatch ?= require('minimatch').Minimatch

    ignoredNames = atom.config.get('core.ignoredNames') ? []
    ignoredNames = [ignoredNames] if typeof ignoredNames is 'string'
    for ignoredName in ignoredNames when ignoredName
      try
        @ignoredPatterns.push(new Minimatch(ignoredName, matchBase: true, dot: true))
      catch error
        console.warn "Error parsing ignore pattern (#{ignoredName}): #{error.message}"

  updateRoots: (expansionStates={}) ->
    oldExpansionStates = {}
    for root in @roots
      oldExpansionStates[root.directory.path] = root.directory.serializeExpansionState()
      root.directory.destroy()
      root.remove()

    @loadIgnoredPatterns()

    @roots = for projectPath in atom.project.getPaths()
      directory = new Directory({
        name: path.basename(projectPath)
        fullPath: projectPath
        symlink: false
        isRoot: true
        expansionState: expansionStates[projectPath] ?
                        oldExpansionStates[projectPath] ?
                        {isExpanded: true}
        @ignoredPatterns
      })
      root = new DirectoryView()
      root.initialize(directory)
      @list[0].appendChild(root)
      root

    if @attachAfterProjectPathSet
      @attach()
      @attachAfterProjectPathSet = false

  getActivePath: -> atom.workspace.getActivePaneItem()?.getPath?()

  selectActiveFile: ->
    if activeFilePath = @getActivePath()
      @selectEntryForPath(activeFilePath)
    else
      @deselect()

  revealActiveFile: ->
    return if _.isEmpty(atom.project.getPaths())

    @attach()
    @focus()

    return unless activeFilePath = @getActivePath()

    relativePath = null
    rootPath = null
    for directory in atom.project.getDirectories()
      if directory.contains(activeFilePath)
        rootPath = directory.getPath()
        relativePath = directory.relativize(activeFilePath)
        break
    return unless relativePath?

    activePathComponents = relativePath.split(path.sep)
    currentPath = rootPath
    for pathComponent in activePathComponents
      currentPath += path.sep + pathComponent
      entry = @entryForPath(currentPath)
      if entry instanceof DirectoryView
        entry.expand()
      else
        @selectEntry(entry)
        @scrollToEntry(entry)

  copySelectedEntryPath: (relativePath = false) ->
    if pathToCopy = @selectedPath
      pathToCopy = atom.project.relativize(pathToCopy) if relativePath
      atom.clipboard.write(pathToCopy)

  entryForPath: (entryPath) ->
    bestMatchEntry = null
    bestMatchLength = 0

    for entry in @list[0].querySelectorAll('.entry')
      if entry.isPathEqual(entryPath)
        return entry

      entryLength = entry.getPath().length
      if entry.directory?.contains(entryPath) and entryLength > bestMatchLength
        bestMatchEntry = entry
        bestMatchLength = entryLength

    bestMatchEntry

  selectEntryForPath: (entryPath) ->
    @selectEntry(@entryForPath(entryPath))

  moveDown: (event) ->
    event.stopImmediatePropagation()
    selectedEntry = @selectedEntry()
    if selectedEntry?
      if selectedEntry instanceof DirectoryView
        if @selectEntry(selectedEntry.entries.children[0])
          @scrollToEntry(@selectedEntry())
          return

      selectedEntry = $(selectedEntry)
      until @selectEntry(selectedEntry.next('.entry')[0])
        selectedEntry = selectedEntry.parents('.entry:first')
        break unless selectedEntry.length
    else
      @selectEntry(@roots[0])

    @scrollToEntry(@selectedEntry())

  moveUp: (event) ->
    event.stopImmediatePropagation()
    selectedEntry = @selectedEntry()
    if selectedEntry?
      selectedEntry = $(selectedEntry)
      if previousEntry = @selectEntry(selectedEntry.prev('.entry')[0])
        if previousEntry instanceof DirectoryView
          @selectEntry(_.last(previousEntry.entries.children))
      else
        @selectEntry(selectedEntry.parents('.directory').first()?[0])
    else
      @selectEntry(@list.find('.entry').last()?[0])

    @scrollToEntry(@selectedEntry())

  expandDirectory: (isRecursive=false) ->
    @selectedEntry()?.expand?(isRecursive)

  collapseDirectory: (isRecursive=false) ->
    selectedEntry = @selectedEntry()
    return unless selectedEntry?

    if directory = $(selectedEntry).closest('.expanded.directory')[0]
      directory.collapse(isRecursive)
      @selectEntry(directory)

  openSelectedEntry: (activatePane) ->
    selectedEntry = @selectedEntry()
    if selectedEntry instanceof DirectoryView
      selectedEntry.toggleExpansion()
    else if selectedEntry instanceof FileView
      atom.workspace.open(selectedEntry.getPath(), {activatePane})

  openSelectedEntrySplit: (orientation, side) ->
    selectedEntry = @selectedEntry()
    pane = atom.workspace.getActivePane()
    if pane and selectedEntry instanceof FileView
      if atom.workspace.getActivePaneItem()
        split = pane.split orientation, side
        atom.workspace.openURIInPane selectedEntry.getPath(), split
      else
        @openSelectedEntry yes

  openSelectedEntryRight: ->
    @openSelectedEntrySplit 'horizontal', 'after'

  openSelectedEntryLeft: ->
    @openSelectedEntrySplit 'horizontal', 'before'

  openSelectedEntryUp: ->
    @openSelectedEntrySplit 'vertical', 'before'

  openSelectedEntryDown: ->
    @openSelectedEntrySplit 'vertical', 'after'

  openSelectedEntryInPane: (index) ->
    selectedEntry = @selectedEntry()
    pane = atom.workspace.getPanes()[index]
    if pane and selectedEntry instanceof FileView
      atom.workspace.openURIInPane selectedEntry.getPath(), pane

  moveSelectedEntry: ->
    if @hasFocus()
      entry = @selectedEntry()
      return if not entry? or entry in @roots
      oldPath = entry.getPath()
    else
      oldPath = @getActivePath()

    if oldPath
      MoveDialog ?= require './move-dialog'
      dialog = new MoveDialog(oldPath)
      dialog.attach()

  # Get the outline of a system call to the current platform's file manager.
  #
  # pathToOpen  - Path to a file or directory.
  # isFile      - True if the path is a file, false otherwise.
  #
  # Returns an object containing a command, a human-readable label, and the
  # arguments.
  fileManagerCommandForPath: (pathToOpen, isFile) ->
    switch process.platform
      when 'darwin'
        command: 'open'
        label: 'Finder'
        args: ['-R', pathToOpen]
      when 'win32'
        args = ["/select,#{pathToOpen}"]

        if process.env.SystemRoot
          command = path.join(process.env.SystemRoot, 'explorer.exe')
        else
          command = 'explorer.exe'

        command: command
        label: 'Explorer'
        args: args
      else
        # Strip the filename from the path to make sure we pass a directory
        # path. If we pass xdg-open a file path, it will open that file in the
        # most suitable application instead, which is not what we want.
        pathToOpen =  path.dirname(pathToOpen) if isFile

        command: 'xdg-open'
        label: 'File Manager'
        args: [pathToOpen]

  showSelectedEntryInFileManager: ->
    entry = @selectedEntry()
    return unless entry

    isFile = entry instanceof FileView
    {command, args, label} = @fileManagerCommandForPath(entry.getPath(), isFile)

    handleError = (errorMessage) ->
      atom.notifications.addError "Opening #{if isFile then 'file' else 'folder'} in #{label} failed",
        detail: errorMessage
        dismissable: true

    errorLines = []
    stderr = (lines) -> errorLines.push(lines)
    exit = (code) ->
      failed = code isnt 0
      errorMessage = errorLines.join('\n')

      # Windows 8 seems to return a 1 with no error output even on success
      if process.platform is 'win32' and code is 1 and not errorMessage
        failed = false

      handleError(errorMessage) if failed

    showProcess = new BufferedProcess({command, args, stderr, exit})
    showProcess.onWillThrowError ({error, handle}) ->
      handle()
      handleError(error?.message)

  openSelectedEntryInNewWindow: ->
    if pathToOpen = @selectedEntry()?.getPath()
      atom.open({pathsToOpen: [pathToOpen], newWindow: true})

  copySelectedEntry: ->
    if @hasFocus()
      entry = @selectedEntry()
      return if entry in @roots
      oldPath = entry?.getPath()
    else
      oldPath = @getActivePath()
    return unless oldPath

    CopyDialog ?= require './copy-dialog'
    dialog = new CopyDialog(oldPath)
    dialog.attach()

  removeSelectedEntries: ->
    if @hasFocus()
      selectedPaths = @selectedPaths()
    else if activePath = @getActivePath()
      selectedPaths = [activePath]

    return unless selectedPaths

    for root in @roots
      if root.getPath() in selectedPaths
        atom.confirm
          message: "The root directory '#{root.directory.name}' can't be removed."
          buttons: ['OK']
        return

    atom.confirm
      message: "Are you sure you want to delete the selected #{if selectedPaths.length > 1 then 'items' else 'item'}?"
      detailedMessage: "You are deleting:\n#{selectedPaths.join('\n')}"
      buttons:
        "Move to Trash": ->
          for selectedPath in selectedPaths
            shell.moveItemToTrash(selectedPath)
        "Cancel": null

  # Public: Copy the path of the selected entry element.
  #         Save the path in localStorage, so that copying from 2 different
  #         instances of atom works as intended
  #
  #
  # Returns `copyPath`.
  copySelectedEntries: ->
    selectedPaths = @selectedPaths()
    return unless selectedPaths and selectedPaths.length > 0
    # save to localStorage so we can paste across multiple open apps
    LocalStorage.removeItem('tree-view:cutPath')
    LocalStorage['tree-view:copyPath'] = JSON.stringify(selectedPaths)

  # Public: Copy the path of the selected entry element.
  #         Save the path in localStorage, so that cutting from 2 different
  #         instances of atom works as intended
  #
  #
  # Returns `cutPath`
  cutSelectedEntries: ->
    selectedPaths = @selectedPaths()
    return unless selectedPaths and selectedPaths.length > 0
    # save to localStorage so we can paste across multiple open apps
    LocalStorage.removeItem('tree-view:copyPath')
    LocalStorage['tree-view:cutPath'] = JSON.stringify(selectedPaths)

  # Public: Paste a copied or cut item.
  #         If a file is selected, the file's parent directory is used as the
  #         paste destination.
  #
  #
  # Returns `destination newPath`.
  pasteEntries: ->
    selectedEntry = @selectedEntry()
    cutPaths = if LocalStorage['tree-view:cutPath'] then JSON.parse(LocalStorage['tree-view:cutPath']) else null
    copiedPaths = if LocalStorage['tree-view:copyPath'] then JSON.parse(LocalStorage['tree-view:copyPath']) else null
    initialPaths = copiedPaths or cutPaths

    catchAndShowFileErrors = (operation) ->
      try
        operation()
      catch error
        atom.notifications.addWarning("Unable to paste paths: #{initialPaths}", detail: error.message)

    for initialPath in initialPaths ? []
      initialPathIsDirectory = fs.isDirectorySync(initialPath)
      if selectedEntry and initialPath and fs.existsSync(initialPath)
        basePath = selectedEntry.getPath()
        basePath = path.dirname(basePath) if selectedEntry instanceof FileView
        newPath = path.join(basePath, path.basename(initialPath))

        if copiedPaths
          # append a number to the file if an item with the same name exists
          fileCounter = 0
          originalNewPath = newPath
          while fs.existsSync(newPath)
            if initialPathIsDirectory
              newPath = "#{originalNewPath}#{fileCounter.toString()}"
            else
              fileArr = originalNewPath.split('.')
              newPath = "#{fileArr[0]}#{fileCounter.toString()}.#{fileArr[1]}"
            fileCounter += 1

          if fs.isDirectorySync(initialPath)
            # use fs.copy to copy directories since read/write will fail for directories
            catchAndShowFileErrors -> fs.copySync(initialPath, newPath)
          else
            # read the old file and write a new one at target location
            catchAndShowFileErrors -> fs.writeFileSync(newPath, fs.readFileSync(initialPath))
        else if cutPaths
          # Only move the target if the cut target doesn't exists and if the newPath
          # is not within the initial path
          unless fs.existsSync(newPath) or !!newPath.match(new RegExp("^#{initialPath}"))
            catchAndShowFileErrors -> fs.moveSync(initialPath, newPath)

  add: (isCreatingFile) ->
    selectedEntry = @selectedEntry() ? @roots[0]
    selectedPath = selectedEntry?.getPath() ? ''

    AddDialog ?= require './add-dialog'
    dialog = new AddDialog(selectedPath, isCreatingFile)
    dialog.on 'directory-created', (event, createdPath) =>
      @entryForPath(createdPath)?.reload()
      @selectEntryForPath(createdPath)
      false
    dialog.on 'file-created', (event, createdPath) ->
      atom.workspace.open(createdPath)
      false
    dialog.attach()

  removeProjectFolder: (e) ->
    pathToRemove = $(e.target).closest(".project-root > .header").find(".name").data("path")

    # TODO: remove this conditional once the addition of Project::removePath
    # is released.
    if atom.project.removePath?
      atom.project.removePath(pathToRemove) if pathToRemove?

  selectedEntry: ->
    @list[0].querySelector('.selected')

  selectEntry: (entry) ->
    return unless entry?

    @selectedPath = entry.getPath()

    selectedEntries = @getSelectedEntries()
    if selectedEntries.length > 1 or selectedEntries[0] isnt entry
      @deselect(selectedEntries)
      entry.classList.add('selected')
    entry

  getSelectedEntries: ->
    @list[0].querySelectorAll('.selected')

  deselect: (elementsToDeselect=@getSelectedEntries()) ->
    selected.classList.remove('selected') for selected in elementsToDeselect
    undefined

  scrollTop: (top) ->
    if top?
      @scroller.scrollTop(top)
    else
      @scroller.scrollTop()

  scrollBottom: (bottom) ->
    if bottom?
      @scroller.scrollBottom(bottom)
    else
      @scroller.scrollBottom()

  scrollToEntry: (entry) ->
    element = if entry instanceof DirectoryView then entry.header else entry
    element?.scrollIntoViewIfNeeded(true) # true = center around item if possible

  scrollToBottom: ->
    if lastEntry = _.last(@list[0].querySelectorAll('.entry'))
      @selectEntry(lastEntry)
      @scrollToEntry(lastEntry)

  scrollToTop: ->
    @selectEntry(@roots[0]) if @roots[0]?
    @scrollTop(0)

  toggleSide: ->
    toggleConfig('tree-view.showOnRightSide')

  onStylesheetsChanged: =>
    return unless @isVisible()

    # Force a redraw so the scrollbars are styled correctly based on the theme
    @element.style.display = 'none'
    @element.offsetWidth
    @element.style.display = 'block'

  onMouseDown: (e) ->
    e.stopPropagation()

    # return early if we're opening a contextual menu (right click) during multi-select mode
    if @multiSelectEnabled() and
       e.currentTarget.classList.contains('selected') and
       # mouse right click or ctrl click as right click on darwin platforms
       (e.button is 2 or e.ctrlKey and process.platform is 'darwin')
      return

    entryToSelect = e.currentTarget

    if e.shiftKey
      @selectContinuousEntries(entryToSelect)
      @showMultiSelectMenu()
    # only allow ctrl click for multi selection on non darwin systems
    else if e.metaKey or (e.ctrlKey and process.platform isnt 'darwin')
      @selectMultipleEntries(entryToSelect)

      # only show the multi select menu if more then one file/directory is selected
      @showMultiSelectMenu() if @selectedPaths().length > 1
    else
      @selectEntry(entryToSelect)
      @showFullMenu()

  onSideToggled: (newValue) ->
    @element.dataset.showOnRightSide = newValue
    if @isVisible()
      @detach()
      @attach()

  # Public: Return an array of paths from all selected items
  #
  # Example: @selectedPaths()
  # => ['selected/path/one', 'selected/path/two', 'selected/path/three']
  # Returns Array of selected item paths
  selectedPaths: ->
    entry.getPath() for entry in @getSelectedEntries()

  # Public: Selects items within a range defined by a currently selected entry and
  #         a new given entry. This is shift+click functionality
  #
  # Returns array of selected elements
  selectContinuousEntries: (entry) ->
    currentSelectedEntry = @selectedEntry()
    parentContainer = $(entry).parent()
    if $.contains(parentContainer[0], currentSelectedEntry)
      entries = parentContainer.find('.entry').toArray()
      entryIndex = entries.indexOf(entry)
      selectedIndex = entries.indexOf(currentSelectedEntry)
      elements = (entries[i] for i in [entryIndex..selectedIndex])

      @deselect()
      element.classList.add('selected') for element in elements

    elements

  # Public: Selects consecutive given entries without clearing previously selected
  #         items. This is cmd+click functionality
  #
  # Returns given entry
  selectMultipleEntries: (entry) ->
    entry?.classList.toggle('selected')
    entry

  # Public: Toggle full-menu class on the main list element to display the full context
  #         menu.
  #
  # Returns noop
  showFullMenu: ->
    @list[0].classList.remove('multi-select')
    @list[0].classList.add('full-menu')

  # Public: Toggle multi-select class on the main list element to display the the
  #         menu with only items that make sense for multi select functionality
  #
  # Returns noop
  showMultiSelectMenu: ->
    @list[0].classList.remove('full-menu')
    @list[0].classList.add('multi-select')

  # Public: Check for multi-select class on the main list
  #
  # Returns boolean
  multiSelectEnabled: ->
    @list[0].classList.contains('multi-select')
