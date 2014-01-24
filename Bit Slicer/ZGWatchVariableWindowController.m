/*
 * Created by Mayur Pawashe on 12/25/13.
 *
 * Copyright (c) 2013 zgcoder
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * Neither the name of the project's author nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 * TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "ZGWatchVariableWindowController.h"
#import "ZGDocumentWindowController.h"
#import "ZGAppController.h"
#import "ZGBreakPointController.h"
#import "ZGDebuggerController.h"
#import "ZGInstruction.h"
#import "ZGBreakPoint.h"
#import "ZGVariable.h"
#import "ZGProcess.h"
#import "ZGCalculator.h"
#import "ZGVirtualMemory.h"
#import "ZGVirtualMemoryHelpers.h"
#import "ZGRegistersController.h"
#import "NSArrayAdditions.h"
#import "ZGMemoryViewerController.h"
#import "ZGDebuggerController.h"
#import "ZGVariableController.h"

@interface ZGWatchVariableWindowController ()

@property (nonatomic, assign) IBOutlet NSProgressIndicator *progressIndicator;
@property (nonatomic, assign) IBOutlet NSTextField *statusTextField;
@property (nonatomic, assign) IBOutlet NSButton *addButton;
@property (nonatomic, assign) IBOutlet NSTableView *tableView;

@property (nonatomic) BOOL shouldIgnoreTableViewSelectionChange;

@property (nonatomic) ZGProcess *watchProcess;
@property (nonatomic) id watchActivity;
@property (nonatomic) NSMutableArray *foundBreakPointAddresses;
@property (nonatomic) NSMutableArray *foundVariables;
@property (nonatomic, copy) watch_variable_completion_t completionHandler;

@end

@implementation ZGWatchVariableWindowController

#pragma mark Birth & Death

- (id)init
{
	self = [super init];
	if (self != nil)
	{
		[[NSNotificationCenter defaultCenter]
		 addObserver:self
		 selector:@selector(applicationWillTerminate:)
		 name:NSApplicationWillTerminateNotification
		 object:nil];
	}
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	self.watchProcess = nil;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
	[[[ZGAppController sharedController] breakPointController] removeObserver:self];
}

- (NSString *)windowNibName
{
	return NSStringFromClass([self class]);
}

#pragma mark Stop Watching

- (void)stopWatchingAndInvokeCompletionHandler:(BOOL)shouldInvokeCompletionHandler
{
	[[[ZGAppController sharedController] breakPointController] removeObserver:self];
	self.watchProcess = nil;
	
	[self.progressIndicator stopAnimation:nil];
	
	[NSApp endSheet:self.window];
	[self.window close];
	
	if (self.watchActivity != nil)
	{
		[[NSProcessInfo processInfo] endActivity:self.watchActivity];
		self.watchActivity = nil;
	}
	
	if (shouldInvokeCompletionHandler)
	{
		NSArray *desiredVariables = [self.foundVariables zgFilterUsingBlock:^(ZGVariable *variable) { return variable.enabled; }];
		for (ZGVariable *variable in desiredVariables)
		{
			variable.enabled = NO;
		}
		self.completionHandler(desiredVariables);
	}
	
	self.completionHandler = nil;
	self.foundVariables = nil;
	self.foundBreakPointAddresses = nil;
}

- (IBAction)stopWatchingAndAddInstructions:(id)sender
{
	[self stopWatchingAndInvokeCompletionHandler:YES];
}

- (IBAction)cancel:(id)sender
{
	[self stopWatchingAndInvokeCompletionHandler:NO];
}

- (void)watchProcessDied:(NSNotification *)notification
{
	if (self.foundVariables.count == 0)
	{
		[self cancel:nil];
	}
	else
	{
		NSInteger result = NSRunAlertPanel(
						[NSString stringWithFormat:@"%@ Died", self.watchProcess.name],
						@"Do you want to add the instructions that were found to the document?",
						@"Add", @"Cancel", nil);
		switch (result)
		{
			case NSAlertDefaultReturn:
				[self stopWatchingAndAddInstructions:nil];
				break;
			case NSAlertAlternateReturn:
				[self cancel:nil];
				break;
		}
	}
}

#pragma mark Misc.

- (void)setWatchProcess:(ZGProcess *)watchProcess
{
	if (_watchProcess != nil)
	{
		[[NSNotificationCenter defaultCenter]
		 removeObserver:self
		 name:ZGTargetProcessDiedNotification
		 object:watchProcess];
	}
	
	_watchProcess = watchProcess;
	
	if (_watchProcess != nil)
	{
		[[NSNotificationCenter defaultCenter]
		 addObserver:self
		 selector:@selector(watchProcessDied:)
		 name:ZGTargetProcessDiedNotification
		 object:watchProcess];
	}
}

- (void)updateAddButton
{
	NSUInteger variableCount = [[self.foundVariables zgFilterUsingBlock:^(ZGVariable *variable) { return variable.enabled; }] count];
	[self.addButton setEnabled:variableCount > 0];
}

#pragma mark Watching

- (void)appendDescription:(NSMutableAttributedString *)description withRegisterEntries:(ZGRegisterEntry *)registerEntries registerLabel:(NSString *)registerLabel boldFont:(NSFont *)boldFont
{
	[description appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n\n"]];
	[description appendAttributedString:[[NSAttributedString alloc] initWithString:registerLabel attributes:@{NSFontAttributeName : boldFont}]];
	[description appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
	
	NSMutableArray *registerLines = [NSMutableArray array];
	
	for (ZGRegisterEntry *registerEntry = registerEntries; !ZG_REGISTER_ENTRY_IS_NULL(registerEntry); registerEntry++)
	{
		NSMutableString *registerLine = [NSMutableString string];
		
		registerLine.string = [NSString stringWithFormat:@"%s = %@", registerEntry->name, [ZGVariable byteArrayStringFromValue:(unsigned char *)registerEntry->value size:registerEntry->size]];
		
		if (registerEntry->type == ZGRegisterGeneralPurpose)
		{
			switch (registerEntry->size)
			{
				case sizeof(uint32_t):
					[registerLine appendFormat:@" (%u)", *(uint32_t *)registerEntry->value];
					break;
				case sizeof(uint64_t):
					[registerLine appendFormat:@" (%llu)", *(uint64_t *)registerEntry->value];
					break;
			}
		}
		
		[registerLines addObject:registerLine];
	}
	
	[description appendAttributedString:[[NSAttributedString alloc] initWithString:[registerLines componentsJoinedByString:@"\n"]]];
}

- (void)dataAccessedByBreakPoint:(ZGBreakPoint *)breakPoint fromInstructionPointer:(ZGMemoryAddress)instructionAddress
{
	NSNumber *instructionAddressNumber = @(instructionAddress);
	if (!self.watchProcess.valid || [self.foundBreakPointAddresses containsObject:instructionAddressNumber]) return;
	
	[self.foundBreakPointAddresses addObject:instructionAddressNumber];
	
	ZGInstruction *instruction = [[[ZGAppController sharedController] debuggerController] findInstructionBeforeAddress:instructionAddress inProcess:self.watchProcess];
	
	if (instruction == nil)
	{
		NSLog(@"ERROR: Couldn't parse instruction before 0x%llX", instructionAddress);
		return;
	}
	
	NSFont *userFont = [NSFont userFontOfSize:12];
	NSFont *boldFont = [[NSFontManager sharedFontManager] fontWithFamily:userFont.familyName traits:NSBoldFontMask weight:0 size:userFont.pointSize];
	
	NSMutableAttributedString *description = [[NSMutableAttributedString alloc] initWithString:instruction.text];
	
	ZGRegisterEntry registerEntries[ZG_MAX_REGISTER_ENTRIES];
	int numberOfGeneralRegisters = [ZGRegistersController getRegisterEntries:registerEntries fromGeneralPurposeThreadState:breakPoint.generalPurposeThreadState is64Bit:self.watchProcess.is64Bit];
	
	[self
	 appendDescription:description
	 withRegisterEntries:registerEntries
	 registerLabel:@"General Purpose Registers"
	 boldFont:boldFont];
	
	[ZGRegistersController getRegisterEntries:registerEntries + numberOfGeneralRegisters fromAVXThreadState:breakPoint.avxState is64Bit:self.watchProcess.is64Bit];
	
	[self
	 appendDescription:description
	 withRegisterEntries:registerEntries + numberOfGeneralRegisters
	 registerLabel:@"Advanced Vector Extension (AVX) Registers"
	 boldFont:boldFont];
	
	instruction.variable.description = description;
	
	instruction.variable.enabled = YES;
	
	[self.foundVariables addObject:instruction.variable];
	
	[self updateAddButton];
	
	[self.tableView reloadData];
	
	NSString *foundInstructionStatus = [NSString stringWithFormat:@"Found instruction \"%@\"", instruction.text];
	
	if (NSClassFromString(@"NSUserNotification"))
	{
		NSUserNotification *userNotification = [[NSUserNotification alloc] init];
		userNotification.title = @"Found Instruction";
		userNotification.subtitle = self.watchProcess.name;
		userNotification.informativeText = foundInstructionStatus;
		[[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:userNotification];
	}
}

- (void)watchVariable:(ZGVariable *)variable withWatchPointType:(ZGWatchPointType)watchPointType inProcess:(ZGProcess *)process attachedToWindow:(NSWindow *)parentWindow completionHandler:(watch_variable_completion_t)completionHandler
{
	ZGBreakPoint *breakPoint = nil;
	if (![[[ZGAppController sharedController] breakPointController] addWatchpointOnVariable:variable inProcess:process watchPointType:watchPointType delegate:self getBreakPoint:&breakPoint])
	{
		NSRunAlertPanel(
						@"Failed to Watch Variable",
						@"A watchpoint could not be added for this variable at this time.",
						@"OK", nil, nil);
		return;
	}
	
	[self window]; // ensure window is loaded
	
	[self updateAddButton];
	
	self.statusTextField.stringValue = [NSString stringWithFormat:@"Watching %lld byte%@ %@ accesses to %@…", breakPoint.watchSize, breakPoint.watchSize != 1 ? @"s" : @"", watchPointType == ZGWatchPointWrite ? @"write" : @"read and write", variable.addressStringValue];
	
	[self.progressIndicator startAnimation:nil];
	[self.tableView reloadData];
	
	[NSApp
	 beginSheet:self.window
	 modalForWindow:parentWindow
	 modalDelegate:nil
	 didEndSelector:nil
	 contextInfo:NULL];
	
	self.watchProcess = process;
	self.completionHandler = completionHandler;
	
	self.foundVariables = [[NSMutableArray alloc] init];
	self.foundBreakPointAddresses = [[NSMutableArray alloc] init];
	
	if ([[NSProcessInfo processInfo] respondsToSelector:@selector(beginActivityWithOptions:reason:)])
	{
		self.watchActivity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated reason:@"Watching Data Accesses"];
	}
}

#pragma mark Selection Accessors

- (NSIndexSet *)selectedVariableIndexes
{
	NSIndexSet *tableIndexSet = self.tableView.selectedRowIndexes;
	NSInteger clickedRow = self.tableView.clickedRow;
	
	return (clickedRow != -1 && ![tableIndexSet containsIndex:clickedRow]) ? [NSIndexSet indexSetWithIndex:clickedRow] : tableIndexSet;
}

- (NSArray *)selectedVariables
{
	return [self.foundVariables objectsAtIndexes:[self selectedVariableIndexes]];
}

#pragma mark Table View

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return self.foundVariables.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	if (rowIndex < 0 || (NSUInteger)rowIndex >= self.foundVariables.count)
	{
		return nil;
	}
	
	ZGVariable *variable = [self.foundVariables objectAtIndex:rowIndex];
	if ([tableColumn.identifier isEqualToString:@"enabled"])
	{
		return @(variable.enabled);
	}
	else if ([tableColumn.identifier isEqualToString:@"address"])
	{
		return [variable addressStringValue];
	}
	else if ([tableColumn.identifier isEqualToString:@"instruction"])
	{
		return variable.name;
	}
	
	return nil;
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	if (rowIndex < 0 || (NSUInteger)rowIndex >= self.foundVariables.count)
	{
		return;
	}
	
	ZGVariable *variable = [self.foundVariables objectAtIndex:rowIndex];
	if ([tableColumn.identifier isEqualToString:@"enabled"])
	{
		variable.enabled = [object boolValue];
		
		NSArray *selectedVariables = [self selectedVariables];
		if (selectedVariables.count > 1 && [selectedVariables containsObject:variable])
		{
			self.shouldIgnoreTableViewSelectionChange = YES;
			for (ZGVariable *selectedVariable in [self selectedVariables])
			{
				if (variable != selectedVariable)
				{
					selectedVariable.enabled = variable.enabled;
				}
			}
		}
		
		[self updateAddButton];
	}
}

- (BOOL)selectionShouldChangeInTableView:(NSTableView *)aTableView
{
	if (self.shouldIgnoreTableViewSelectionChange)
	{
		self.shouldIgnoreTableViewSelectionChange = NO;
		return NO;
	}
	
	return YES;
}

- (BOOL)validateUserInterfaceItem:(NSMenuItem *)menuItem
{
	if ([menuItem action] == @selector(showMemoryViewer:) || [menuItem action] == @selector(showDebugger:))
	{
		if ([[self selectedVariables] count] != 1 || self.watchProcess == nil)
		{
			return NO;
		}
	}
	else if ([menuItem action] == @selector(copy:))
	{
		if ([[self selectedVariables] count] == 0)
		{
			return NO;
		}
	}
	else if ([menuItem action] == @selector(copyAddress:))
	{
		if ([[self selectedVariables] count] != 1)
		{
			return NO;
		}
	}
	
	return YES;
}

#pragma mark Actions

- (IBAction)copy:(id)sender
{
	[ZGVariableController copyVariablesToPasteboard:[self selectedVariables]];
}

- (IBAction)copyAddress:(id)sender
{
	[ZGVariableController copyVariableAddress:[[self selectedVariables] objectAtIndex:0]];
}

- (IBAction)showMemoryViewer:(id)sender
{
	ZGVariable *selectedVariable = [[self selectedVariables] objectAtIndex:0];
	[[[ZGAppController sharedController] memoryViewer] jumpToMemoryAddress:selectedVariable.address withSelectionLength:selectedVariable.size inProcess:self.watchProcess];
}

- (IBAction)showDebugger:(id)sender
{
	ZGVariable *selectedVariable = [[self selectedVariables] objectAtIndex:0];
	[[[ZGAppController sharedController] debuggerController] showWindow:self];
	[[[ZGAppController sharedController] debuggerController] jumpToMemoryAddress:selectedVariable.address inProcess:self.watchProcess];
}

@end
