package fscript;

class Test {
    
    private static var testNum = 0;
    private static var tests = [
        ["0", 0],
        ["0",0],
		["0xFF",255],
		["-123",-123],
		["- 123",-123],
		["1.546",1.546],
		[".545",.545],
		["'bla'","bla"],
		["null",null],
		["true",true],
		["false",false],
		["1 == 2",false],
		["1.3 == 1.3",true],
		["5 > 3",true],
		["0 < 0",false],
		["-1 <= -1",true],
		["1 + 2",3],
		["~545",-546],
		["'abc' + 55","abc55"],
		["'abc' + 'de'","abcde"],
		["-1 + 2",1],
		["1 / 5",0.2],
		["3 * 2 + 5",11],
		["3 * (2 + 5)",21],
		["3 * 2 // + 5 \n + 6",12],
		["3 /* 2\n */ + 5",8],
		["[55,66,77][1]",66],
		["var a = [55]; a[0] *= 2; a[0]",110],
		["x",55,{ x : 55 }],
		["var y = 33; y",33],
		["{ 1; 2; 3; }",3],
		["{ var x = 0; } x",55,{ x : 55 }],
		["o.val",55,{ o : { val : 55 } }],
		["o.val",null,{ o : {} }],
		["var a = 1; a++",1],
		["var a = 1; a++; a",2],
		["var a = 1; ++a",2],
		["var a = 1; a *= 3",3],
		//["a = b = 3; a + b",6],
		["add(1,2)",3,{ add : function(x,y) return x + y }],
		["a.push(5); a.pop() + a.pop()",8,{ a : [3] }],
		["if( true ) 1 else 2",1],
		["if( false ) 1 else 2",2],
		["var t = 0; for( x in [1,2,3] ) t += x; t",6],
		["var a = new Array(); for( x in 0...5 ) a[x] = x; a.join('-')","0-1-2-3-4"],
		["(function(a,b) return a + b)(4,5)",9],
		["var y = 0; var add = function(a) y += a; add(5); add(3); y", 8],
		["var a = [1,[2,[3,[4,null]]]]; var t = 0; while( a != null ) { t += a[0]; a = a[1]; }; t",10],
		["var t = 0; for( x in 1...10 ) t += x; t",45],
		["var t = 0; for( x in new IntIter(1,10) ) t +=x; t",45],
		["var x = 1; try { var x = 66; throw 789; } catch( e : Dynamic ) e + x",790],
		["var x = 1; var f = function(x) throw x; try f(55) catch( e : Dynamic ) e + x",56],
    ];
    
	static function test() {
        if (testNum == tests.length) {
            trace("DONE");
            return;
        }
        
		var p = new hscript.Parser();
		var program = p.parseString(tests[testNum][0]);
        
		var interp = new fscript.FInterp();
		if( tests[testNum].length == 3)
			for( v in Reflect.fields(tests[testNum][2]) )
				interp.variables.set(v,Reflect.field(tests[testNum][2],v));
        
        trace(tests[testNum][0]);
        interp.execute(program, 
            function (ret) {
                if(tests[testNum][1] != ret ) throw ret+" returned while "+tests[testNum][1]+" expected";
                trace(testNum++);
                test();
            }
        );
	}

	public static function main() {
		test();
	}
}