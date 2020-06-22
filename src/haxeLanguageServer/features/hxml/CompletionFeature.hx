package haxeLanguageServer.features.hxml;

import haxeLanguageServer.features.hxml.HxmlContextAnalyzer;
import haxeLanguageServer.features.hxml.data.Defines;
import haxeLanguageServer.features.hxml.data.Flags;
import haxeLanguageServer.helper.TextEditCompletionItem;
import haxeLanguageServer.helper.VscodeCommands;
import jsonrpc.CancellationToken;
import jsonrpc.ResponseError;
import jsonrpc.Types.NoData;

using Lambda;

class CompletionFeature {
	final context:Context;

	public function new(context) {
		this.context = context;
	}

	public function onCompletion(params:CompletionParams, token:CancellationToken, resolve:CompletionList->Void, reject:ResponseError<NoData>->Void) {
		final uri = params.textDocument.uri;
		final doc = context.documents.getHxml(uri);
		if (doc == null) {
			return reject.noFittingDocument(uri);
		}
		final pos = params.position;
		final line = doc.lineAt(pos.line);
		final textBefore = line.substr(0, pos.character);
		final textAfter = line.substr(pos.character);
		final hxmlContext = analyzeHxmlContext(textBefore, pos);
		resolve({
			isIncomplete: false,
			items: switch hxmlContext.element {
				case Flag(_): createFlagCompletion(hxmlContext.range, textAfter);
				case EnumValue(_, values):
					final items:Array<CompletionItem> = [
						for (value in values)
							{
								label: value.name,
								kind: EnumMember,
								documentation: value.description
							}
					];
					items[0].preselect = true;
					items;
				case Define(): createDefineCompletion();
				case DefineValue(define, value):
					[
						{
							label: "value"
						}
					];
				case Unknown: [];
			}
		});
	}

	function createFlagCompletion(range:Range, textAfter:String):Array<CompletionItem> {
		final items = [];
		function addFlag(flag:Flag, name:String) {
			final item:TextEditCompletionItem = {
				label: name,
				textEdit: {
					range: range,
					newText: name
				},
				filterText: name,
				kind: Function,
				documentation: {
					kind: MarkDown,
					value: flag.description
				},
				insertTextFormat: Snippet
			}
			final arg = flag.argument;
			if (arg != null) {
				item.label += " " + arg.name;
				if (textAfter.charAt(0) != " ") {
					item.textEdit.newText += " ";
				}
				if (arg.insertion != null) {
					var insertion = arg.insertion;
					if (!insertion.contains("$")) {
						insertion = '$${1:$insertion}';
					}
					item.textEdit.newText += insertion;
				}
				if (arg.kind != null) {
					item.command = TriggerSuggest;
				}
			}
			items.push(item);
		}
		for (flag in HxmlFlags.flatten()) {
			addFlag(flag, flag.name);
			if (flag.shortName != null) {
				addFlag(flag, flag.shortName);
			}
		}
		return items;
	}

	function createDefineCompletion():Array<CompletionItem> {
		final haxeVersion = context.haxeServer.haxeVersion;
		return getDefines(false).map(define -> {
			final item:CompletionItem = {
				label: define.getRealName(),
				kind: Constant,
				documentation: {
					kind: MarkDown,
					value: define.printDetails(haxeVersion)
				}
			}
			if (define.hasParams()) {
				item.insertText = item.label + "=";
				item.command = TriggerSuggest;
			}
			if (!define.isAvailable(haxeVersion)) {
				item.tags = [Deprecated];
			}
			return item;
		});
	}
}
