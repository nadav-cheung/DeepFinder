// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Darwin

import Foundation

import DeepFinderCLILib



@main

struct CLIEntry {

    static func main() async {

        let args = Array(CommandLine.arguments.dropFirst())

        let result = await CLIMain.run(args: args)



        if !result.output.stdout.isEmpty {

            FileHandle.standardOutput.write(

                Data(result.output.stdout.utf8)

            )

        }

        if !result.output.stderr.isEmpty {

            FileHandle.standardError.write(

                Data(result.output.stderr.utf8)

            )

        }



        Darwin.exit(result.exitCode.rawValue)

    }

}
