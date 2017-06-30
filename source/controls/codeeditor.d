module controls.codeeditor;

import deadcode.edit.bufferview;
import deadcode.gui.controls.texteditor;
import deadcode.gui.widget;

class CodeEditor : TextEditor
{
	/*
	Source code editor
	* indent policy (auto?, on tab?)
	* tab width
	* completions
	* parenthesis highligting
	* line markers
	* margin marker
	* draw spaces
	* bookmarks
	* selection (should also work for simple text rendering)
	* undo/redo
	* move line/word
	* linelayout caching (textrenderer)
	*
	*/
	this(BufferView buf)
	{
		super(buf);
	}
}
