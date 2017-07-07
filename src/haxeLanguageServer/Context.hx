package haxeLanguageServer;

import haxe.Timer;
import jsonrpc.CancellationToken;
import jsonrpc.ResponseError;
import jsonrpc.Types;
import jsonrpc.Protocol;
import haxeLanguageServer.features.*;
import haxeLanguageServer.features.CodeActionFeature.CodeActionContributor;
import haxeLanguageServer.helper.SemVer;
import haxeLanguageServer.helper.TypeHelper.FunctionFormattingConfig;
import haxeLanguageServer.HaxeServer.DisplayResult;

private typedef DisplayServerConfigBase = {
    var haxePath:String;
    var arguments:Array<String>;
    var env:haxe.DynamicAccess<String>;
}

private typedef DisplayServerConfig = {
    >DisplayServerConfigBase,
    @:optional var windows:DisplayServerConfigBase;
    @:optional var linux:DisplayServerConfigBase;
    @:optional var osx:DisplayServerConfigBase;
}

private typedef FunctionGenerationConfig = {
    @:optional var anonymous:FunctionFormattingConfig;
}

private typedef CodeGenerationConfig = {
    @:optional var functions:FunctionGenerationConfig;
}

private typedef Config = {
    var displayConfigurations:Array<Array<String>>;
    var enableDiagnostics:Bool;
    var diagnosticsPathFilter:String;
    var enableCodeLens:Bool;
    var displayServer:DisplayServerConfig;
    var displayPort:Null<Int>;
    var buildCompletionCache:Bool;
    var codeGeneration:CodeGenerationConfig;
    var format:haxeFormatter.Config;
}

private typedef InitOptions = {
    var displayArguments:Array<String>;
}

class Context {
    static var systemKey = switch (Sys.systemName()) {
        case "Windows": "windows";
        case "Mac": "osx";
        default: "linux";
    };

    public var workspacePath(default,null):FsPath;
    public var displayArguments(default,null):Array<String>;
    public var protocol(default,null):Protocol;
    public var haxeServer(default,null):HaxeServer;
    public var documents(default,null):TextDocuments;
    public var signatureHelp(default,null):SignatureHelpFeature;
    public var displayOffsetConverter(default,null):DisplayOffsetConverter;
    public var gotoDefinition(default,null):GotoDefinitionFeature;
    var diagnostics:DiagnosticsManager;
    var codeActions:CodeActionFeature;

    public var config(default,null):Config;
    @:allow(haxeLanguageServer.HaxeServer)
    var displayServerConfig:DisplayServerConfigBase;
    var displayConfigurationIndex:Int;

    var progressId = 0;

    public function new(protocol) {
        this.protocol = protocol;

        haxeServer = new HaxeServer(this);

        protocol.onRequest(Methods.Initialize, onInitialize);
        protocol.onRequest(Methods.Shutdown, onShutdown);
        protocol.onNotification(Methods.DidChangeConfiguration, onDidChangeConfiguration);
        protocol.onNotification(Methods.DidOpenTextDocument, onDidOpenTextDocument);
        protocol.onNotification(Methods.DidSaveTextDocument, onDidSaveTextDocument);
        protocol.onNotification(Methods.DidChangeWatchedFiles, onDidChangeWatchedFiles);
        protocol.onNotification(VshaxeMethods.DidChangeDisplayArguments, onDidChangeDisplayArguments);
        protocol.onNotification(VshaxeMethods.DidChangeActiveTextEditor, onDidChangeActiveTextEditor);
    }

    public function startProgress(title:String):Void->Void {
        var id = progressId++;
        protocol.sendNotification(VshaxeMethods.ProgressStart, {id: id, title: 'Haxe: $title...'});
        return function() {
            protocol.sendNotification(VshaxeMethods.ProgressStop, {id: id});
        };
    }

    public inline function sendShowMessage(type:MessageType, message:String) {
        protocol.sendNotification(Methods.ShowMessage, {type: type, message: message});
    }

    public inline function sendLogMessage(type:MessageType, message:String) {
        protocol.sendNotification(Methods.LogMessage, {type: type, message: message});
    }

    function onInitialize(params:InitializeParams, token:CancellationToken, resolve:InitializeResult->Void, reject:ResponseError<InitializeError>->Void) {
        workspacePath = new FsPath(params.rootPath);
        displayArguments = (params.initializationOptions : InitOptions).displayArguments;
        documents = new TextDocuments(protocol);
        return resolve({
            capabilities: {
                textDocumentSync: TextDocuments.syncKind,
                completionProvider: {
                    triggerCharacters: [".", "@", ":"]
                },
                signatureHelpProvider: {
                    triggerCharacters: ["(", ","]
                },
                definitionProvider: true,
                hoverProvider: true,
                referencesProvider: true,
                documentSymbolProvider: true,
                workspaceSymbolProvider: true,
                codeActionProvider: true,
                #if debug
                documentFormattingProvider: true,
                #end
                codeLensProvider: {
                    resolveProvider: true
                },
                renameProvider: true
            }
        });
    }

    function onDidChangeDisplayArguments(params:{arguments:Array<String>}) {
        displayArguments = params.arguments;
        haxeServer.restart("display arguments changed");
    }

    function onShutdown(_, token:CancellationToken, resolve:NoData->Void, _) {
        haxeServer.stop();
        haxeServer = null;
        return resolve(null);
    }

    function onDidChangeConfiguration(newConfig:DidChangeConfigurationParams) {
        var firstInit = (config == null);

        config = newConfig.settings.haxe;
        updateDisplayServerConfig();
        updateCodeGenerationConfig();

        if (firstInit) {
            haxeServer.start(function() {
                displayOffsetConverter = DisplayOffsetConverter.create(haxeServer.version);
                codeActions = new CodeActionFeature(this);

                new CompletionFeature(this);
                new HoverFeature(this);
                signatureHelp = new SignatureHelpFeature(this);
                gotoDefinition = new GotoDefinitionFeature(this);
                new FindReferencesFeature(this);
                new DocumentSymbolsFeature(this);
                new DeterminePackageFeature(this);
                new RenameFeature(this);

                diagnostics = new DiagnosticsManager(this);
                new CodeLensFeature(this);
                new CodeGenerationFeature(this);

                #if debug
                new DocumentFormattingFeature(this);
                #end

                for (doc in documents.getAll())
                    publishDiagnostics(doc.uri);
            });
        } else {
            haxeServer.restart("configuration was changed", function() {
                displayOffsetConverter = DisplayOffsetConverter.create(haxeServer.version);
            });
        }

        checkLanguageFeatures();
    }

    function updateDisplayServerConfig() {
        displayServerConfig = {
            haxePath: "haxe",
            arguments: [],
            env: {},
        };

        function merge(conf:DisplayServerConfigBase) {
            if (conf.haxePath != null)
                displayServerConfig.haxePath = conf.haxePath;
            if (conf.arguments != null)
                displayServerConfig.arguments = conf.arguments;
            if (conf.env != null)
                displayServerConfig.env = conf.env;
        }

        var conf = config.displayServer;
        if (conf != null) {
            merge(conf);
            var sysConf:DisplayServerConfigBase = Reflect.field(conf, systemKey);
            if (sysConf != null)
                merge(sysConf);
        }
    }

    function updateCodeGenerationConfig() {
        var codeGen = config.codeGeneration;
        if (codeGen.functions == null)
            codeGen.functions = {};

        var functions = codeGen.functions;
        if (functions.anonymous == null)
            functions.anonymous = {argumentTypeHints: false, returnTypeHint: Never, useArrowSyntax: true};
    }

    function checkLanguageFeatures() {
        var hasArrowFunctions = haxeServer.version >= new SemVer(4, 0, 0);
        if (!hasArrowFunctions)
            config.codeGeneration.functions.anonymous.useArrowSyntax = false;
    }

    function onDidOpenTextDocument(event:DidOpenTextDocumentParams) {
        documents.onDidOpenTextDocument(event);
        publishDiagnostics(event.textDocument.uri);
    }

    function onDidSaveTextDocument(event:DidSaveTextDocumentParams) {
        publishDiagnostics(event.textDocument.uri);
    }

    function onDidChangeWatchedFiles(event:DidChangeWatchedFilesParams) {
        for (change in event.changes) {
            if (change.type == Deleted) {
                diagnostics.clearDiagnostics(change.uri);
            }
        }
    }

    function onDidChangeActiveTextEditor(params:{uri:DocumentUri}) {
        var document = documents.get(params.uri);
        if (document == null)
            return;
        // avoid running diagnostics twice when the document is initially opened (open + activate event)
        var timeSinceOpened = Timer.stamp() - document.openTimestamp;
        if (timeSinceOpened > 0.1)
            publishDiagnostics(params.uri);
    }

    function publishDiagnostics(uri:DocumentUri) {
        if (diagnostics != null && config.enableDiagnostics)
            diagnostics.publishDiagnostics(uri);
    }

    public function callDisplay(args:Array<String>, stdin:String, token:CancellationToken, callback:DisplayResult->Void, errback:String->Void) {
        var actualArgs = ["--cwd", workspacePath.toString()]; // change cwd to workspace root
        if (displayArguments != null)
            actualArgs = actualArgs.concat(displayArguments); // add arguments from the workspace settings
        actualArgs = actualArgs.concat([
            "-D", "display-details", // get more details in completion results,
            "--no-output", // prevent anygeneration
        ]);
        actualArgs = actualArgs.concat(args); // finally, add given query args
        haxeServer.process(actualArgs, token, stdin, callback, errback);
    }

    public function registerCodeActionContributor(contributor:CodeActionContributor) {
        codeActions.registerContributor(contributor);
    }
}
