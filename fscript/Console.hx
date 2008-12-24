
package fscript;

import flash.display.Sprite;
import flash.text.TextField;
import flash.text.TextFieldType;
import flash.events.MouseEvent;
import hscript.Parser;

class Console extends Sprite {
    
    public static inline var BUTTON_HEIGHT = 25;
    
    public var text     : TextField;
    public var button   : Sprite;
    public var traceBox : TextField;
    
    public function new(width = 500, height = 300) {
        super();
        
        text                    = new TextField();
        text.width              = width;
        text.height             = height - BUTTON_HEIGHT;
        text.text               = "trace('HELLO WORLD!');";
        text.type               = TextFieldType.INPUT;
        text.multiline          = true;
        addChild(text);
        
        button                  = new Sprite();
        button.graphics.beginFill(0x000000, 1.0);
        button.graphics.drawRect(0, height - BUTTON_HEIGHT, 
                                 width, BUTTON_HEIGHT);
        button.graphics.endFill();
        button.useHandCursor    = true;
        
        var buttonText          = new TextField();
        buttonText.textColor    = 0xFFFFFF;
        buttonText.text         = "RUN";
        buttonText.y            = height - BUTTON_HEIGHT;
        buttonText.selectable   = false;
        
        button.addChild(buttonText);
        addChild(button);
        
        button.addEventListener(MouseEvent.CLICK, run);
        
        traceBox                = new TextField();
        traceBox.y              = height;
        traceBox.width          = width;
        traceBox.height         = flash.Lib.current.stage.height - height;
        traceBox.multiline      = true;
        addChild(traceBox);
        
        var me                  = this;
        haxe.Log.trace          = function(v, ?posInfo) {
            me.traceBox.text    += Std.string(v) + "\n";
        };
    }
    
    public function run(?e : Dynamic) {
        try {
            traceBox.text   = "";
            
            var program     = new Parser().parseString(text.text);
            
            var interp      = new FInterp();
            
            interp.variables.set("Math", Math);
            interp.variables.set("Date", Date);
            interp.variables.set("root", flash.Lib.current);
            
            interp.variables.set("n", 
                function(c : Dynamic, args : Array<Dynamic>) : Dynamic {
                    return Type.createInstance(c, args);
                }
            );
            
            interp.variables.set("c", 
                function(name : String) : Dynamic {
                    return Type.resolveClass(name);
                }
            );
            
            interp.execute(program, function(_) {} );
        } catch (e : Dynamic) {
            trace("ERROR: " + e);
        }
    }
}